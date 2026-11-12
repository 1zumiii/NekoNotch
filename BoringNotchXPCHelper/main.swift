//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import Security

/// Who may connect: the app this helper ships in. With a Team ID (a
/// developer-signed build) the requirement also pins Apple's anchor and that
/// team. An ad-hoc signed build has no team to pin, so it checks the
/// identifier alone; the system already limits an embedded XPC service to
/// its own app, and this is a second check on top of that.
private enum XPCClientRequirement {
    static let appIdentifier = "theboringteam.boringnotch"

    static let value: String = {
        let identifier = #"identifier "\#(appIdentifier)""#
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [CFString: Any])?[kSecCodeInfoTeamIdentifier] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            return identifier
        }
        return identifier + #" and anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
    }()
}

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only the user this helper runs for.
        guard newConnection.effectiveUserIdentifier == geteuid() else {
            newConnection.invalidate()
            return false
        }
        // Checked on each message. Set per connection: on the listener of an
        // XPC service, setConnectionCodeSigningRequirement crashes at launch.
        newConnection.setCodeSigningRequirement(XPCClientRequirement.value)

        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)

        // Configure the interface for callbacks from the helper to the app.
        let listenerInterface = NSXPCInterface(with: (any BoringNotchXPCAppDelegate).self)
        listenerInterface.setClasses(
            NSSet(array: [BNLunarBrightnessEvent.self]) as! Set<AnyHashable>,
            for: #selector(BoringNotchXPCHelperLunarListener.lunarEventDidUpdate(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.remoteObjectInterface = listenerInterface

        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper(connection: newConnection)
        newConnection.exportedObject = exportedObject

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()

        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
