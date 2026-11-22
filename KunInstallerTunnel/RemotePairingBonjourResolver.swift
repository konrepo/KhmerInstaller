import Foundation

final class RemotePairingBonjourResolver: NSObject,
    NetServiceBrowserDelegate,
    NetServiceDelegate
{
    struct ResolvedService {
        let name: String
        let host: String
        let port: Int
        let identifier: String
        let authTag: Data
    }

    private let browser = NetServiceBrowser()

    private var services: [NetService] = []

    var onResolved: ((ResolvedService) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        services.removeAll()

        print("NetService tunnel browser starting")

        browser.searchForServices(
            ofType: "_remotepairing._tcp.",
            inDomain: "local."
        )
    }

    func stop() {
        browser.stop()

        for service in services {
            service.stop()
        }

        services.removeAll()

        print("NetService tunnel browser stopped")
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        print(
            "NS SERVICE FOUND:",
            service.name,
            service.type,
            service.domain
        )

        services.append(service)

        service.delegate = self

        service.resolve(withTimeout: 5.0)
    }

    func netServiceDidResolveAddress(
        _ sender: NetService
    ) {
        print(
            "NS SERVICE RESOLVED:",
            sender.name
        )

        guard
            let host = sender.hostName,
            sender.port > 0,
            let txtData = sender.txtRecordData()
        else {
            print("NS SERVICE missing host/port/TXT")
            return
        }

        let txt =
            NetService.dictionary(
                fromTXTRecord: txtData
            )

        guard
            let identifierData = txt["identifier"],
            let identifier =
                String(
                    data: identifierData,
                    encoding: .utf8
                ),
            let authTagData = txt["authTag"],
            let authTagString =
                String(
                    data: authTagData,
                    encoding: .utf8
                ),
            let authTag =
                Data(
                    base64Encoded: authTagString
                ),
            authTag.count == 6
        else {
            print(
                "NS SERVICE missing/invalid identifier or authTag"
            )
            return
        }

        let resolved =
            ResolvedService(
                name: sender.name,
                host: host,
                port: sender.port,
                identifier: identifier,
                authTag: authTag
            )

        print(
            "RESOLVED TUNNEL SERVICE:",
            resolved.name
        )

        print(
            "  host:",
            resolved.host
        )

        print(
            "  port:",
            resolved.port
        )

        print(
            "  identifier:",
            resolved.identifier
        )

        print(
            "  authTag:",
            resolved.authTag
                .map {
                    String(format: "%02x", $0)
                }
                .joined()
        )

        onResolved?(resolved)
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String : NSNumber]
    ) {
        print(
            "NS SERVICE FAILED:",
            sender.name,
            errorDict
        )
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String : NSNumber]
    ) {
        print(
            "NS BROWSER FAILED:",
            errorDict
        )
    }
}
