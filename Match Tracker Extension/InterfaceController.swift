//
//  InterfaceController.swift
//  Match Tracker Extension
//
//  Created by Ben Lachman on 9/9/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import WatchKit
import WatchConnectivity
import Foundation


class InterfaceController: WKInterfaceController, CLLocationManagerDelegate, WCSessionDelegate {
    lazy var locationManager = CLLocationManager()
    

    @IBOutlet var timer: WKInterfaceTimer!
    
    
    @IBAction func startMatch() {
        timer.setDate(Date())

        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways:
            DispatchQueue.main.async {
                self.locationManager.startUpdatingLocation()
            }
        case .notDetermined:
            DispatchQueue.main.async {
                self.locationManager.requestAlwaysAuthorization()
            }

            if WCSession.default.isReachable {
                WCSession.default.sendMessage(["requestLocation": true], replyHandler: nil) { (error) in
                    print(error.localizedDescription)
                }
            }
        default:
            print("Status: \(CLLocationManager.authorizationStatus())")
        }

        timer.start()
    }

    @IBAction func stopMatch() {
        timer.stop()

        DispatchQueue.main.async {
            self.locationManager.stopUpdatingLocation()
        }
    }

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        
        DispatchQueue.main.async {
            self.locationManager.delegate = self
            self.locationManager.requestAlwaysAuthorization()
            self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    override func willActivate() {
        // This method is called when watch view controller is about to be visible to user
        super.willActivate()
    }
    
    override func didDeactivate() {
        // This method is called when watch view controller is no longer visible
        super.didDeactivate()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print(error.localizedDescription)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            print("Authorized Always")
        case .notDetermined:
            print("Not Determined: \(status.rawValue)")
        default:
            print("Not Authorized: \(status.rawValue)")
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        if let shouldRequestLocation = message["requestLocation"] as? Bool, shouldRequestLocation == true {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print(error.localizedDescription)
        }
    }

//    func sessionDidBecomeInactive(_ session: WCSession) {
//        print("WCSession inactived")
//    }
//
//    func sessionDidDeactivate(_ session: WCSession) {
//        print("WCSession deactived")
//    }

}
