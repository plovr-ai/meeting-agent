import Foundation

public enum AppRuntimeCapabilities {
    public static func supportsUserNotifications(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.pathExtension == "app"
    }
}
