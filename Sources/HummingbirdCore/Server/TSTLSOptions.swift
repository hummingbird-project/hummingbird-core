//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import Foundation
import Network

extension tls_protocol_version_t {
    var sslProtocol: SSLProtocol {
        switch self {

        case .TLSv10:
            return .tlsProtocol1
        case .TLSv11:
            return .tlsProtocol11
        case .TLSv12:
            return .tlsProtocol12
        case .TLSv13:
            return .tlsProtocol13
        case .DTLSv10:
            return .dtlsProtocol1
        case .DTLSv12:
            return .dtlsProtocol12
        @unknown default:
            return .tlsProtocol1
        }
    }
}

/// Certificate verification modes.
public enum TSCertificateVerification {
    /// All certificate verification disabled.
    case none

    /// Certificates will be validated against the trust store and checked
    /// against the hostname of the service we are contacting.
    case fullVerification
}

/// Wrapper for NIO transport services TLS options
public struct TSTLSOptions {
    @available(macOS 10.14, iOS 12, tvOS 12, *)
    public enum ServerIdentity {
        case secIdentity(SecIdentity)
        case p12(filename: String, password: String)
    }

    /// Initialize TSTLSOptions
    @available(macOS 10.14, iOS 12, tvOS 12, *)
    public init(_ options: NWProtocolTLS.Options?) {
        if let options = options {
            self.value = .some(options)
        } else {
            self.value = .none
        }
    }

    /// TSTLSOptions holding options
    @available(macOS 10.14, iOS 12, tvOS 12, *)
    public static func options(_ options: NWProtocolTLS.Options) -> Self {
        return .init(.some(options))
    }

    @available(macOS 10.14, iOS 12, tvOS 12, *)
    public static func options(
        serverIdentity: ServerIdentity,
        trustRoots: [SecCertificate]? = nil,
        certificateVerification: TSCertificateVerification = .none,
        applicationProtocols: [String]? = nil,
        minimumTLSVersion: tls_protocol_version_t = .TLSv10,
        maximumTLSVersion: tls_protocol_version_t? = nil
    ) -> Self? {
        let options = NWProtocolTLS.Options()
        // server identity
        let identity: SecIdentity
        switch serverIdentity {
        case .secIdentity(let serverIdentity):
            identity = serverIdentity
        case .p12(let filename, let password):
            guard let identity2 = loadP12(filename: filename, password: password) else { return nil }
            identity = identity2
        }

        guard let secIdentity = sec_identity_create(identity) else { return nil }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)

        // application protocols
        applicationProtocols?.forEach {
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, $0)
        }

        // min TLS version
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, minimumTLSVersion)
        } else {
            sec_protocol_options_set_tls_min_version(options.securityProtocolOptions, minimumTLSVersion.sslProtocol)
        }

        // max TLS version
        if let maximumTLSVersion = maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion)
            } else {
                sec_protocol_options_set_tls_max_version(options.securityProtocolOptions, maximumTLSVersion.sslProtocol)
            }
        }

        if certificateVerification != .fullVerification || trustRoots != nil {
            // add verify block to control certificate verification
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { sec_metadata, sec_trust, sec_protocol_verify_complete in
                    guard certificateVerification != .none else {
                        sec_protocol_verify_complete(true)
                        return
                    }

                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    if let trustRootCertificates = trustRoots {
                        SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                    }
                    if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                        SecTrustEvaluateAsyncWithError(trust, Self.tlsDispatchQueue) { (trust, result, error) in
                            sec_protocol_verify_complete(result)
                        }
                    } else {
                        SecTrustEvaluateAsync(trust, Self.tlsDispatchQueue) { (trust, result) in
                             switch result {
                             case .proceed, .unspecified:
                                sec_protocol_verify_complete(true)
                             default:
                                sec_protocol_verify_complete(false)
                             }
                        }
                    }
                }, Self.tlsDispatchQueue
            )
        }
        return .init(.some(options))
    }

    /// Empty TSTLSOptions
    public static var none: Self {
        return .init(.none)
    }

    @available(macOS 10.14, iOS 12, tvOS 12, *)
    var options: NWProtocolTLS.Options? {
        if case .some(let options) = self.value { return options as? NWProtocolTLS.Options }
        return nil
    }

    /// Internal storage for TSTLSOptions. Originally stored a reference to the NWProtocolTLS.Options
    /// class but we cannot use @available with enum values that hold associated values anymore
    private enum Internal {
        case some(Any)
        case none
    }

    private let value: Internal
    private init(_ value: Internal) { self.value = value }

    static private func loadP12(filename: String, password: String) -> SecIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filename)) else { return nil }
        let options: [String: String] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems) == errSecSuccess else { return nil }
        let items = rawItems! as! Array<Dictionary<String, Any>>
        let firstItem = items[0]
        return firstItem[kSecImportItemIdentity as String] as! SecIdentity?
    }

    /// Dispatch queue used by Network framework TLS to control certificate verification
    static private var tlsDispatchQueue = DispatchQueue(label: "TSTLSOptions")
}
#endif

