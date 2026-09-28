/**
 * Field Capture brand logo — the Acme Oilfield Services circular badge (assets/fieldLogo.png),
 * clipped to a circle. Used in the header, splash, and sign-in. Pure image, no native dep.
 */
import { Image, StyleSheet, View } from 'react-native';

import { palette } from './theme';

// Static require so Metro bundles the asset (the standard RN image pattern).
const LOGO_SOURCE = require('../../assets/fieldLogo.png');

export function Logo(props: { size?: number; ring?: boolean; testID?: string }) {
  const size = props.size ?? 36;
  const radius = size / 2;
  return (
    <View
      testID={props.testID}
      style={[
        styles.wrap,
        { width: size, height: size, borderRadius: radius },
        props.ring ? styles.ring : null,
      ]}
    >
      <Image
        source={LOGO_SOURCE}
        style={{ width: size, height: size, borderRadius: radius }}
        resizeMode="cover"
        accessibilityLabel="Field Capture"
      />
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    overflow: 'hidden',
    backgroundColor: palette.surface,
  },
  ring: {
    borderWidth: 2,
    borderColor: palette.skyBlue,
  },
});
