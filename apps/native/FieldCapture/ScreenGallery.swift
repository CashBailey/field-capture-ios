//
//  ScreenGallery.swift
//  Debug-only screen gallery: browsable list of every ported screen with demo defaults, plus a
//  launch-argument jump (`-GalleryScreen <Name>`) so simulator test sweeps can screenshot each
//  screen headlessly. Production builds always mount the real app shell.
//

import SwiftUI

#if DEBUG

    struct GalleryEntry: Identifiable {
        let name: String
        let view: AnyView
        var id: String { name }
    }

    struct ScreenGalleryView: View {
        static let all: [GalleryEntry] =
            entriesUnauth + entriesDay + entriesPreTrip + entriesJha + entriesJob
            + entriesFieldTicket + entriesEvidence + entriesSop + entriesSopExtra
            + entriesPostTrip + entriesSync + entriesMore + entriesAdmin

        @Environment(\.fieldTheme) private var theme

        var body: some View {
            ZStack {
                theme.background.ignoresSafeArea()

                if let key = UserDefaults.standard.string(forKey: "GalleryScreen"),
                    let entry = Self.all.first(where: { $0.name == key })
                {
                    ScrollView { entry.view }
                } else {
                    NavigationStack {
                        List(Self.all) { entry in
                            NavigationLink(entry.name) {
                                ZStack {
                                    theme.background.ignoresSafeArea()
                                    ScrollView { entry.view }
                                }
                            }
                        }
                        .navigationTitle("Screens (\(Self.all.count))")
                    }
                }
            }
        }

        static let entriesUnauth: [GalleryEntry] = [
            GalleryEntry(name: "SignInHelpScreen", view: AnyView(SignInHelpScreen(onBack: {}))),
            GalleryEntry(
                name: "OfflineSavedWorkScreen", view: AnyView(OfflineSavedWorkScreen(onContinue: {}, onRetry: {}))),
            GalleryEntry(name: "FirstRunPermissionsScreen", view: AnyView(FirstRunPermissionsScreen(onFinish: {}))),
            GalleryEntry(name: "SessionExpiredScreen", view: AnyView(SessionExpiredScreen(onSignInAgain: {}))),
        ]

        static let entriesDay: [GalleryEntry] = [
            GalleryEntry(
                name: "DayDashboardScreen",
                view: AnyView(
                    DayDashboardScreen(
                        punchedIn: true, jobsCount: 3, needsReview: 1, pendingSync: 2, timeline: [],
                        primaryLabel: "Start Pre-Trip", onPrimary: {}, onOpenJobs: {}, onRefresh: {})))
        ]

        static let entriesPreTrip: [GalleryEntry] = [
            GalleryEntry(name: "PreTripOverviewScreen", view: AnyView(PreTripOverviewScreen(onBeginInspection: {}))),
            GalleryEntry(name: "PreTripSectionScreen", view: AnyView(PreTripSectionScreen(onContinue: { _ in }))),
            GalleryEntry(name: "DefectDetailScreen", view: AnyView(DefectDetailScreen(onSaveDefect: {}, onCancel: {}))),
            GalleryEntry(name: "PreTripReviewScreen", view: AnyView(PreTripReviewScreen(onContinueToSignature: {}))),
            GalleryEntry(
                name: "PreTripSignatureScreen", view: AnyView(PreTripSignatureScreen(onCompletePreTrip: { _ in }))),
            GalleryEntry(name: "PreTripCompleteScreen", view: AnyView(PreTripCompleteScreen(onStartNextJob: {}))),
        ]

        static let entriesJha: [GalleryEntry] = [
            GalleryEntry(name: "JhaOverviewScreen", view: AnyView(JhaOverviewScreen(onBegin: {}))),
            GalleryEntry(name: "JhaJobAndSiteScreen", view: AnyView(JhaJobAndSiteScreen(onNext: {}))),
            GalleryEntry(name: "JhaEmergencyInfoScreen", view: AnyView(JhaEmergencyInfoScreen(onNext: {}))),
            GalleryEntry(name: "JhaPreJobSafetyScreen", view: AnyView(JhaPreJobSafetyScreen(onNext: {}))),
            GalleryEntry(name: "JhaPpeScreen", view: AnyView(JhaPpeScreen(onNext: {}))),
            GalleryEntry(name: "JhaHazardsScreen", view: AnyView(JhaHazardsScreen(onNext: {}))),
            GalleryEntry(name: "JhaJobStepsScreen", view: AnyView(JhaJobStepsScreen(onNext: {}))),
            GalleryEntry(name: "JhaStopWorkScreen", view: AnyView(JhaStopWorkScreen(onAcknowledge: {}))),
            GalleryEntry(name: "JhaSignaturesScreen", view: AnyView(JhaSignaturesScreen(onContinue: { _ in }))),
            GalleryEntry(name: "JhaReviewScreen", view: AnyView(JhaReviewScreen(onComplete: {}))),
            GalleryEntry(name: "JhaCompleteScreen", view: AnyView(JhaCompleteScreen(onStartFieldTicket: {}))),
        ]

        static let entriesJob: [GalleryEntry] = [
            GalleryEntry(name: "JobsListScreen", view: AnyView(JobsListScreen())),
            GalleryEntry(name: "JobOverviewScreen", view: AnyView(JobOverviewScreen())),
            GalleryEntry(name: "JobDetailsScreen", view: AnyView(JobDetailsScreen())),
            GalleryEntry(name: "JobSopsScreen", view: AnyView(JobSopsScreen())),
            GalleryEntry(name: "EmergencyInfoScreen", view: AnyView(EmergencyInfoScreen())),
            GalleryEntry(name: "StopWorkScreen", view: AnyView(StopWorkScreen())),
        ]

        static let entriesFieldTicket: [GalleryEntry] = [
            GalleryEntry(
                name: "FieldTicketOverviewScreen",
                view: AnyView(FieldTicketOverviewScreen(jhaComplete: true, onBegin: {}))),
            GalleryEntry(name: "FieldTicketJobInfoScreen", view: AnyView(FieldTicketJobInfoScreen(onNext: {}))),
            GalleryEntry(name: "FieldTicketTimesScreen", view: AnyView(FieldTicketTimesScreen(onNext: {}))),
            GalleryEntry(name: "FieldTicketLoadTank1Screen", view: AnyView(FieldTicketLoadTank1Screen(onNext: {}))),
            GalleryEntry(name: "FieldTicketLoadTank2Screen", view: AnyView(FieldTicketLoadTank2Screen(onNext: {}))),
            GalleryEntry(name: "FieldTicketLineItemsScreen", view: AnyView(FieldTicketLineItemsScreen(onNext: {}))),
            GalleryEntry(name: "FieldTicketEvidenceScreen", view: AnyView(FieldTicketEvidenceScreen(onReview: {}))),
            GalleryEntry(name: "FieldTicketReviewScreen", view: AnyView(FieldTicketReviewScreen(onSubmit: {}))),
            GalleryEntry(
                name: "FieldTicketSubmittedScreen", view: AnyView(FieldTicketSubmittedScreen(onReviewJob: {}))),
        ]

        static let entriesEvidence: [GalleryEntry] = [
            GalleryEntry(name: "JobEvidenceScreen", view: AnyView(JobEvidenceScreen())),
            GalleryEntry(name: "CameraCaptureScreen", view: AnyView(CameraCaptureScreen())),
            GalleryEntry(name: "PhotoReviewScreen", view: AnyView(PhotoReviewScreen())),
            GalleryEntry(name: "ReceiptCaptureScreen", view: AnyView(ReceiptCaptureScreen())),
            GalleryEntry(name: "ReceiptFormScreen", view: AnyView(ReceiptFormScreen())),
            GalleryEntry(name: "SignatureCaptureScreen", view: AnyView(SignatureCaptureScreen())),
            GalleryEntry(name: "GpsCaptureScreen", view: AnyView(GpsCaptureScreen())),
            GalleryEntry(name: "PrintTicketScreen", view: AnyView(PrintTicketScreen())),
            GalleryEntry(name: "JobCompleteReviewScreen", view: AnyView(JobCompleteReviewScreen())),
        ]

        static let entriesSop: [GalleryEntry] = [
            GalleryEntry(name: "SopLibraryScreen", view: AnyView(SopLibraryScreen()))
        ]

        static let entriesSopExtra: [GalleryEntry] = [
            GalleryEntry(
                name: "RequiredDriverSopsScreen", view: AnyView(RequiredDriverSopsScreen(onOpenSop: { _ in }))),
            GalleryEntry(name: "JobSpecificSopsScreen", view: AnyView(JobSpecificSopsScreen(onOpenSop: { _ in }))),
            GalleryEntry(name: "EmergencySopsScreen", view: AnyView(EmergencySopsScreen(onOpenSop: { _ in }))),
            GalleryEntry(
                name: "RecentlyUpdatedSopsScreen", view: AnyView(RecentlyUpdatedSopsScreen(onReviewSop: { _ in }))),
            GalleryEntry(name: "SopSearchScreen", view: AnyView(SopSearchScreen(onOpenSop: { _ in }))),
            GalleryEntry(name: "SopReaderScreen", view: AnyView(SopReaderScreen(onAcknowledge: {}, onBackToJob: {}))),
            GalleryEntry(
                name: "SopAcknowledgementScreen",
                view: AnyView(SopAcknowledgementScreen(onAcknowledge: {}, onCancel: {}))),
        ]

        static let entriesPostTrip: [GalleryEntry] = [
            GalleryEntry(
                name: "EndDayReviewScreen",
                view: AnyView(EndDayReviewScreen(onStartPostTrip: {}, onContactDispatch: {}))),
            GalleryEntry(name: "PostTripOverviewScreen", view: AnyView(PostTripOverviewScreen(onBegin: {}))),
            GalleryEntry(name: "PostTripSectionScreen", view: AnyView(PostTripSectionScreen(onContinue: {}))),
            GalleryEntry(name: "PostTripReviewScreen", view: AnyView(PostTripReviewScreen(onContinue: {}))),
            GalleryEntry(name: "PostTripSignatureScreen", view: AnyView(PostTripSignatureScreen(onComplete: { _ in }))),
            GalleryEntry(name: "PostTripCompleteScreen", view: AnyView(PostTripCompleteScreen(onDone: {}))),
            GalleryEntry(
                name: "PunchOutScreen",
                view: AnyView(PunchOutScreen(onPunchOut: {}, onReviewJobs: {}, onViewSync: {}, onContactDispatch: {}))),
            GalleryEntry(
                name: "PunchOutConfirmScreen", view: AnyView(PunchOutConfirmScreen(onConfirm: {}, onCancel: {}))),
            GalleryEntry(
                name: "PunchOutSuccessScreen", view: AnyView(PunchOutSuccessScreen(onViewSync: {}, onDone: {}))),
        ]

        static let entriesSync: [GalleryEntry] = [
            GalleryEntry(
                name: "SyncHomeScreen",
                view: AnyView(SyncHomeScreen(onSyncNow: {}, onViewPending: {}, onViewFailed: {}))),
            GalleryEntry(
                name: "PendingSyncItemsScreen",
                view: AnyView(PendingSyncItemsScreen(onSyncNow: {}, onOpenItem: { _ in }))),
            GalleryEntry(
                name: "SyncFailedItemsScreen",
                view: AnyView(
                    SyncFailedItemsScreen(onRetry: { _ in }, onViewDetails: { _ in }, onContactSupport: { _ in }))
            ),
            GalleryEntry(name: "SyncItemDetailScreen", view: AnyView(SyncItemDetailScreen())),
            GalleryEntry(name: "SyncCompleteScreen", view: AnyView(SyncCompleteScreen(onDone: {}))),
        ]

        static let entriesMore: [GalleryEntry] = [
            GalleryEntry(
                name: "MoreHomeScreen",
                view: AnyView(
                    MoreHomeScreen(
                        onOpenAccount: {}, onOpenTheme: {}, onOpenTextSize: {}, onOpenPrinter: {}, onOpenHelp: {},
                        onOpenContactDispatch: {}, onOpenAdminMode: {}, onSignOut: {}))),
            GalleryEntry(name: "AccountScreen", view: AnyView(AccountScreen())),
            GalleryEntry(name: "LanguageScreen", view: AnyView(LanguageScreen(onSelect: { _ in }))),
            GalleryEntry(name: "ThemeScreen", view: AnyView(ThemeScreen())),
            GalleryEntry(
                name: "TextSizeScreen",
                view: AnyView(
                    TextSizeScreen(
                        onSelectSize: { _ in }, onToggleHighContrast: { _ in }, onToggleReduceMotion: { _ in }))),
            GalleryEntry(name: "PrinterSettingsScreen", view: AnyView(PrinterSettingsScreen())),
            GalleryEntry(name: "HelpSupportScreen", view: AnyView(HelpSupportScreen())),
            GalleryEntry(name: "ContactDispatchScreen", view: AnyView(ContactDispatchScreen())),
            GalleryEntry(
                name: "SignOutConfirmScreen", view: AnyView(SignOutConfirmScreen(onCancel: {}, onConfirmSignOut: {}))),
        ]

        static let entriesAdmin: [GalleryEntry] = [
            GalleryEntry(
                name: "AdminModeLockScreen", view: AnyView(AdminModeLockScreen(onUnlock: { _ in }, onCancel: {}))),
            GalleryEntry(
                name: "AdminDashboardScreen",
                view: AnyView(AdminDashboardScreen(onOpenSection: { _ in }, onLockAdmin: {}))),
            GalleryEntry(name: "PrinterDiagnosticsScreen", view: AnyView(PrinterDiagnosticsScreen())),
            GalleryEntry(name: "SyncDiagnosticsScreen", view: AnyView(SyncDiagnosticsScreen())),
            GalleryEntry(name: "EnvironmentDetailsScreen", view: AnyView(EnvironmentDetailsScreen())),
            GalleryEntry(name: "LogsExportScreen", view: AnyView(LogsExportScreen())),
            GalleryEntry(
                name: "SupervisorDefectReviewScreen", view: AnyView(SupervisorDefectReviewScreen(onDecision: { _ in }))),
            GalleryEntry(
                name: "MechanicDefectResolutionScreen",
                view: AnyView(MechanicDefectResolutionScreen(onSelect: { _ in }))),
            GalleryEntry(name: "SupervisorOverrideScreen", view: AnyView(SupervisorOverrideScreen(onApply: { _ in }))),
        ]
    }

#endif
