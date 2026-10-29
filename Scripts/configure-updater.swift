// Read the 32-byte base64 Sparkle seed from stdin; never print the private key.
import Foundation
import CryptoKit
func fail(_ message:String)->Never { FileHandle.standardError.write(Data((message+"\n").utf8)); exit(1) }
guard CommandLine.arguments.count == 2 else { fail("Usage: swift configure-updater.swift path/to/Info.plist < private-key-file") }
let encoded=String(decoding:FileHandle.standardInput.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
guard let seed=Data(base64Encoded:encoded),seed.count==32 else { fail("Sparkle signing key must be a base64-encoded 32-byte seed. No key was printed.") }
do {
    let key=try Curve25519.Signing.PrivateKey(rawRepresentation:seed)
    let url=URL(fileURLWithPath:CommandLine.arguments[1])
    guard var info=try PropertyListSerialization.propertyList(from:Data(contentsOf:url),format:nil) as? [String:Any] else { fail("Invalid Info.plist") }
    let publicKey=key.publicKey.rawRepresentation.base64EncodedString()
    info["SUPublicEDKey"]=publicKey
    let data=try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0)
    try data.write(to:url,options:.atomic)
    print(publicKey)
} catch { fail("Unable to configure the updater public key. No key was printed.") }
