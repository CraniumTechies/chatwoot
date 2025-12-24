/**
 * Composable for branding-related utilities
 * Provides methods to customize text with installation-specific branding
 */

export function useBranding() {
  /**
   * Replaces "Chatwoot" in text with the installation name from global config
   * @param {string} text - The text to process
   * @returns {string} - Text with "Chatwoot" replaced by installation name
   */
  const replaceInstallationName = text => {
    if (!text) return text;

    const installationName = 'Nyota';
    if (!installationName) return text;

    return text.replace(/Chatwoot/g, installationName);
  };

  return {
    replaceInstallationName,
  };
}
