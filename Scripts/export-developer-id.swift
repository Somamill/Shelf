// Export only the selected Developer ID identity, never the whole keychain.
import Foundation
import Security
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
var result: CFTypeRef?
let query: [String: Any] = [kSecClass as String: kSecClassIdentity,
    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnRef as String: true]
let status = SecItemCopyMatching(query as CFDictionary, &result)
if status == errSecItemNotFound { print("[]"); exit(0) }
guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
    fail("Cannot read signing identities from the login keychain (\(status)).")
}
var matches: [(SecIdentity, String)] = []
for identity in identities {
    var cert: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { continue }
    let name = SecCertificateCopySubjectSummary(cert) as String? ?? ""
    guard name.hasPrefix("Developer ID Application:") else { continue }
    matches.append((identity, name))
}
if CommandLine.arguments.count == 1 {
    let rows = matches.enumerated().map { ["index":String($0.offset), "name":$0.element.1] }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows))
    exit(0)
}
guard CommandLine.arguments.count == 3, let index = Int(CommandLine.arguments[1]),
      matches.indices.contains(index) else { fail("Usage: export-developer-id.swift [index output.p12]") }
let password = String(decoding:FileHandle.standardInput.readDataToEndOfFile(),as:UTF8.self)
guard !password.isEmpty else { fail("Missing temporary export password.") }
var params = SecItemImportExportKeyParameters()
params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
let exportPassphrase = Unmanaged<CFTypeRef>.passRetained(password as CFString)
defer { exportPassphrase.release() }
params.passphrase = exportPassphrase
var exported: CFData?
let exportStatus = SecItemExport(matches[index].0, .formatPKCS12, [], &params, &exported)
guard exportStatus == errSecSuccess, let exported else {
    fail("Developer ID export failed (\(exportStatus)). Allow the login-keychain export if macOS asks.")
}
let url = URL(fileURLWithPath:CommandLine.arguments[2])
try (exported as Data).write(to:url,options:.atomic)
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
