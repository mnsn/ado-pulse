import ADOPulseCore
import AppKit

/// Opening Azure DevOps pages, and signing in to the Azure CLI.
@MainActor
enum AzureDevOps {
    static let installCLIPage = URL(string: "https://learn.microsoft.com/cli/azure/install-azure-cli-macos")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The "My pull requests" page of the first organization.
    static func openPullRequests(organizations: [String]) {
        guard let organization = organizations.first else {
            open(URL(string: "https://dev.azure.com")!)
            return
        }
        open(ADOEndpoint.myPullRequestsPage(organization: organization))
    }

    /// Opens Terminal running `az login`, which signs in through the browser. ADO Pulse picks the sign-in up
    /// on its next refresh, within a minute.
    static func signIn(azPath: String?) {
        let az = azPath.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" } ?? "az"
        let script = """
            #!/bin/zsh -l
            # Opened by ADO Pulse, which reads your pull requests with the Azure CLI's sign-in.
            echo "Signing in to the Azure CLI for ADO Pulse. Your browser will open."
            echo
            \(az) login --allow-no-subscriptions --output none && echo && echo "Signed in. You can close this window: ADO Pulse will refresh within a minute."
            """
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(AppSettings.domain, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Sign in to Azure CLI.command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            Log.app.error("Couldn't start az login: \(error.localizedDescription, privacy: .public)")
        }
    }
}
