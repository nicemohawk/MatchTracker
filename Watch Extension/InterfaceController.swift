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
import HealthKit

class InterfaceController: WKInterfaceController, CLLocationManagerDelegate, WCSessionDelegate {
    override func awake(withContext context: Any?) {
        super.awake(withContext: context)

        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

    override func didAppear() {
        super.didAppear()

        let typesToShare: Set = [ HKObjectType.workoutType(),
                                  HKObjectType.seriesType(forIdentifier: HKWorkoutRouteTypeIdentifier)! ]

        let typesToRead: Set = [ HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
                                 HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
                                 HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
                                 HKObjectType.quantityType(forIdentifier: .heartRate)! ]

        HKHealthStore().requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
            // completion
            if let error = error {
                print("HK authorization error: \(String(describing:error))")
            }
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

    @IBAction func startMatchAction() {
        WKInterfaceController.reloadRootPageControllers(withNames: ["WorkoutControls", "WorkoutDisplay"], contexts: nil, orientation: .horizontal, pageIndex: 1)
    }

    
    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
//        if let shouldRequestLocation = message["requestLocation"] as? Bool, shouldRequestLocation == true {
//            locationManager.requestAlwaysAuthorization()
//       }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("WCSession: " + error.localizedDescription)
            return
        }

        session.sendMessage(["requestLocation" : true], replyHandler: nil, errorHandler: nil)
    }

//    func sessionDidBecomeInactive(_ session: WCSession) {
//        print("WCSession inactived")
//    }
//
//    func sessionDidDeactivate(_ session: WCSession) {
//        print("WCSession deactived")
//    }

}
