// Value-only bridge between the presentational safety screens and the durable field-form
// contracts. The wizard owns these values above route switches so leaving a step cannot erase a
// worker's answers. No persistence or network work belongs here.

import Foundation
import FieldContracts

struct DvirDefectDraft: Equatable {
    var note = ""
    var requiresReview = false
    var severity: DefectSeverity = .minor
    var photoCount = 0
}

struct DvirSubmissionPayload {
    var signature: SignatureValue
    var signerName: String
    var items: [FieldContracts.InspectionItem]
    var defectsCertifiedSafe: Bool?
}

struct JhaSubmissionPayload {
    var hazards: [FieldContracts.JhaHazard]
    var signatures: [SignatureSubmitPayload]
}

private func contractResult(_ result: InspectionResult) -> FieldContracts.InspectionResult? {
    switch result {
    case .notChecked: return nil
    case .ok: return .ok
    case .defect: return .defect
    }
}

func contractInspectionItems(
    _ items: [InspectionItem],
    defects: [String: DvirDefectDraft]
) -> [FieldContracts.InspectionItem] {
    items.map { item in
        let result = contractResult(item.result)
        let note: String? = {
            guard result == .defect, let defect = defects[item.key] else { return nil }
            var lines = [defect.note.trimmingCharacters(in: .whitespacesAndNewlines)]
            lines.append("Severity: \(defect.severity.evidenceLabel)")
            lines.append("Requires review: \(defect.requiresReview ? "Yes" : "No")")
            return lines.filter { !$0.isEmpty }.joined(separator: "\n")
        }()
        return FieldContracts.InspectionItem(
            itemId: item.key,
            label: item.label,
            result: result,
            note: note?.isEmpty == true ? nil : note
        )
    }
}

func contractInspectionItems(_ items: [PostTripItem]) -> [FieldContracts.InspectionItem] {
    items.map { item in
        let result = contractResult(item.result)
        let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return FieldContracts.InspectionItem(
            itemId: item.key,
            label: item.label,
            result: result,
            note: result == .defect && !note.isEmpty ? note : nil
        )
    }
}

private extension DefectSeverity {
    var evidenceLabel: String {
        switch self {
        case .minor: return "Minor"
        case .needsReview: return "Needs Review"
        case .unsafe: return "Unsafe"
        }
    }
}

/// Preserve every affirmative JHA input inside the Hub's existing hazard/mitigation evidence shape.
/// Namespaced IDs keep catalog hazards, pre-job checks, PPE, job steps, and acknowledgements distinct
/// without adding unsupported wire fields.
func contractJhaHazards(
    preJobGroups: [JhaCheckGroup],
    dvirCompleted: Bool,
    ppe: [JhaSelectable],
    otherPpe: String,
    selectedHazards: [JhaHazard],
    jobSteps: [JhaJobStep],
    stopWorkAcknowledged: Bool
) -> [FieldContracts.JhaHazard] {
    let preJob = preJobGroups.flatMap { group in
        group.items.map { item in
            let confirmed = item.key == "dvir-pre-trip" ? (dvirCompleted || item.ok) : item.ok
            return FieldContracts.JhaHazard(
                hazardId: "prejob:\(group.key):\(item.key)",
                description: "Pre-job safety — \(item.label)",
                mitigation: confirmed ? "Confirmed OK" : "Not confirmed"
            )
        }
    }
    let selectedPpe = ppe.filter(\.selected).map { item in
        let detail =
            item.key == "other"
            ? otherPpe.trimmingCharacters(in: .whitespacesAndNewlines)
            : item.label
        return FieldContracts.JhaHazard(
            hazardId: "ppe:\(item.key)",
            description: "Required PPE — \(item.label)",
            mitigation: "Selected and reviewed\(detail.isEmpty ? "" : ": \(detail)")"
        )
    }
    let selected = selectedHazards.filter(\.selected).map { hazard in
        FieldContracts.JhaHazard(
            hazardId: "hazard:\(hazard.key)",
            description: hazard.label,
            mitigation: hazard.controls.joined(separator: "; ")
        )
    }
    let steps = jobSteps.map { step in
        let risk = calcRiskScore(step.severity, step.likelihood)
        return FieldContracts.JhaHazard(
            hazardId: "step:\(step.key)",
            description: "\(step.title): \(step.hazards.trimmingCharacters(in: .whitespacesAndNewlines))",
            mitigation: [
                step.controls.trimmingCharacters(in: .whitespacesAndNewlines),
                "Severity: \(Int(step.severity.rounded()))",
                "Likelihood: \(Int(step.likelihood.rounded()))",
                "Risk score: \(risk)",
                "Worker initials: \(step.initials.trimmingCharacters(in: .whitespacesAndNewlines))",
            ].joined(separator: "\n")
        )
    }
    let stopWork = FieldContracts.JhaHazard(
        hazardId: "ack:stop-work",
        description: "Stop-work authority",
        mitigation: stopWorkAcknowledged ? "Reviewed and acknowledged" : "Not acknowledged"
    )
    return preJob + selectedPpe + selected + steps + [stopWork]
}
