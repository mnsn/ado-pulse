// Finds the certificate that ADO Pulse is signed with, and imports and checks its private key, for
// scripts/signing.sh (which scripts/build-app.sh, scripts/sign-package.sh and
// scripts/make-signing-identity.sh use) and scripts/import-signing-certificate.sh.
// macOS ties ADO Pulse's Full Disk Access to the certificate, so any app that may use its key without
// asking could sign itself as ADO Pulse and get that access. So the key trusts no app, not even codesign
// or security, and macOS asks for your login password each time it's used. And it can't be exported,
// not even by an app you allow. (security import -T "" trusts no app either, but its -x has no effect on
// a PKCS #12: the key can still be exported.)
//
//   swift scripts/signing-key.swift import <keychain> <name> [--trust <app>]
//       Imports a PKCS #12 identity: its password on the first line of standard input, then the file
//       in base64. <name> describes the key when macOS asks to use it. --trust lets that app use the key
//       without asking: only for a keychain of its own, like the release workflow's. Fails with status
//       3, after importing it, if the key can be exported or another app may use it without asking.
//   swift scripts/signing-key.swift find <name> [keychain]
//       Prints the SHA-1 of the one identity whose certificate is named exactly <name>, to sign with
//       rather than the name: given a name, codesign uses an identity preference by that name if there is
//       one, and otherwise a certificate whose name merely contains it. Fails with status 1 if there's
//       none, and 4 if there's more than one.
//   swift scripts/signing-key.swift check <name or SHA-1> [keychain]
//       Fails with status 3 if the key of the certificate named exactly <name>, or with that SHA-1, can
//       be exported, or some app may use it without asking, and says which; with status 1 if there's no
//       such certificate, and 2 if it can't tell.
// Both read only certificates and the keys' attributes and access lists, with user interaction off, so
// macOS never asks anything. Without a keychain, they look where codesign does: the search list.
import CryptoKit
import Foundation
import Security

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("signing-key: \(message)\n".utf8))
    exit(status)
}

func openKeychain(_ path: String) -> SecKeychain {
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { fail("can't open \(path)") }
    return keychain
}

/// The access list entries that let an app use the private key, or change who may. The others let any
/// app encrypt, which a private key isn't used for, or are macOS's own bookkeeping.
let usesOfTheKey = Set([
    kSecACLAuthorizationAny, kSecACLAuthorizationSign, kSecACLAuthorizationDecrypt, kSecACLAuthorizationDerive,
    kSecACLAuthorizationMAC, kSecACLAuthorizationExportWrapped, kSecACLAuthorizationExportClear,
    kSecACLAuthorizationChangeACL, kSecACLAuthorizationChangeOwner,
].map { $0 as String })

/// Who may use a key without asking, and whether it can be exported.
struct Exposure {
    var apps: Set<String> = []
    var exportable = false
}

/// Nil if it can't tell.
func exposure(of identity: SecIdentity) -> Exposure? {
    var key: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
          let attributes = SecKeyCopyAttributes(key) as? [String: Any],
          let exportable = attributes[kSecAttrIsExtractable as String] as? Bool
    else { return nil }
    var exposure = Exposure(exportable: exportable)

    var access: SecAccess?
    var list: CFArray?
    guard SecKeychainItemCopyAccess(unsafeBitCast(key, to: SecKeychainItem.self), &access) == errSecSuccess, let access,
          SecAccessCopyACLList(access, &list) == errSecSuccess, let entries = list as? [SecACL]
    else { return nil }
    for entry in entries {
        let authorizations = SecACLCopyAuthorizations(entry) as? [String] ?? []
        guard !usesOfTheKey.isDisjoint(with: authorizations) else { continue }
        var apps: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        guard SecACLCopyContents(entry, &apps, &description, &prompt) == errSecSuccess else { return nil }
        // No list at all means any app.
        guard let apps = apps as? [SecTrustedApplication] else {
            exposure.apps.insert("any app")
            continue
        }
        for app in apps {
            var data: CFData?
            SecTrustedApplicationCopyData(app, &data)
            let path = data.map { String(decoding: $0 as Data, as: UTF8.self) }?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            exposure.apps.insert(path ?? "an app")
        }
    }
    return exposure
}

/// What's wrong with a key, beyond the apps it's meant to trust.
func issues(with exposure: Exposure, name: String, trusting trusted: Set<String> = []) -> [String] {
    var problems: [String] = []
    let others = exposure.apps.subtracting(trusted)
    if !others.isEmpty {
        problems.append("these may use the key of \"\(name)\" without asking: \(others.sorted().joined(separator: ", "))")
    }
    if exposure.exportable {
        problems.append("the key of \"\(name)\" can be exported")
    }
    return problems
}

func importIdentity(into path: String, name: String, trusting trustedPaths: [String]) -> Never {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let lines = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    guard lines.count == 2, !lines[0].isEmpty,
          let data = Data(base64Encoded: String(lines[1]), options: .ignoreUnknownCharacters), !data.isEmpty
    else { fail("expected a password line, then a base64 PKCS #12, on standard input") }
    let passphrase = String(lines[0]) as CFString

    let trusted = trustedPaths.map { app -> SecTrustedApplication in
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(app, &trustedApp) == errSecSuccess, let trustedApp else {
            fail("can't trust \(app)")
        }
        return trustedApp
    }
    // An empty list trusts no app at all. Without an access object, the key would trust the app that
    // imports it.
    var access: SecAccess?
    guard SecAccessCreate(name as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
        fail("can't create the key's access list")
    }
    // Without kSecAttrIsExtractable, the key never leaves the keychain.
    let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray

    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged<AnyObject>.passUnretained(passphrase)
    parameters.accessRef = Unmanaged.passUnretained(access)
    parameters.keyAttributes = Unmanaged.passUnretained(attributes)
    var format = SecExternalFormat.formatPKCS12
    var type = SecExternalItemType.itemTypeAggregate
    var items: CFArray?
    let keychain = openKeychain(path)
    let status = withExtendedLifetime((passphrase, access, attributes)) {
        SecItemImport(data as CFData, nil, &format, &type, [], &parameters, keychain, &items)
    }
    guard status == errSecSuccess else { fail("the import failed (\(status))") }

    // Check what macOS made of it.
    let identities = (items as? [AnyObject] ?? []).filter { CFGetTypeID($0) == SecIdentityGetTypeID() }
    guard !identities.isEmpty else { fail("the PKCS #12 has no certificate and private key") }
    for item in identities {
        guard let exposure = exposure(of: item as! SecIdentity) else {
            fail("can't tell who may use the key it imported", status: 2)
        }
        let found = issues(with: exposure, name: name, trusting: Set(trustedPaths))
        guard found.isEmpty else { fail(found.joined(separator: "; "), status: 3) }
    }
    exit(0)
}

/// Every identity in the keychain at `path`, or on the search list, with its certificate's common name and SHA-1.
func identities(in path: String?) -> [(identity: SecIdentity, name: String?, sha1: String)] {
    // Anything that would need a prompt fails instead.
    SecKeychainSetUserInteractionAllowed(false)
    var query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
    ]
    if let path {
        query[kSecMatchSearchList as String] = [openKeychain(path)]
    }
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail("can't list the identities (\(status))", status: 2) }
    return (result as? [SecIdentity] ?? []).compactMap { identity in
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(certificate, &name)
        let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
        return (identity, name as String?, sha1)
    }
}

func isSHA1(_ text: String) -> Bool {
    text.count == 40 && text.allSatisfy(\.isHexDigit)
}

func findIdentity(named name: String, in path: String?) -> Never {
    // The same certificate in more than one keychain is still one identity.
    let hashes = Set(identities(in: path).filter { $0.name == name }.map(\.sha1))
    guard let hash = hashes.first else { fail("there's no certificate named \"\(name)\" with its private key") }
    guard hashes.count == 1 else {
        fail("there's more than one certificate named \"\(name)\": \(hashes.sorted().joined(separator: ", "))", status: 4)
    }
    print(hash)
    exit(0)
}

func checkKey(of certificate: String, in path: String?) -> Never {
    let sha1 = isSHA1(certificate) ? certificate.uppercased() : nil
    var found = false
    var problems: [String] = []
    for item in identities(in: path) where sha1.map({ $0 == item.sha1 }) ?? (item.name == certificate) {
        found = true
        let name = item.name ?? item.sha1
        guard let exposure = exposure(of: item.identity) else {
            fail("can't tell who may use the key of \"\(name)\"", status: 2)
        }
        problems += issues(with: exposure, name: name)
    }
    guard found else { fail("there's no certificate \(sha1 == nil ? "named " : "")\"\(certificate)\" with its private key") }
    guard problems.isEmpty else { fail(Array(Set(problems)).sorted().joined(separator: "; "), status: 3) }
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "import" where arguments.count == 3:
    importIdentity(into: arguments[1], name: arguments[2], trusting: [])
case "import" where arguments.count == 5 && arguments[3] == "--trust":
    importIdentity(into: arguments[1], name: arguments[2], trusting: [arguments[4]])
case "find" where arguments.count == 2 || arguments.count == 3:
    findIdentity(named: arguments[1], in: arguments.count == 3 ? arguments[2] : nil)
case "check" where arguments.count == 2 || arguments.count == 3:
    checkKey(of: arguments[1], in: arguments.count == 3 ? arguments[2] : nil)
default:
    fail("usage: signing-key.swift import <keychain> <name> [--trust <app>] | find <name> [keychain] | check <name or SHA-1> [keychain]",
         status: 64)
}
