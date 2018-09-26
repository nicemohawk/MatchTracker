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

class InterfaceController: WKInterfaceController, CLLocationManagerDelegate, WCSessionDelegate, HKWorkoutSessionDelegate {
    lazy var healthStore = HKHealthStore()
    lazy var locationManager = CLLocationManager()

    var routeBuilder: HKWorkoutRouteBuilder?
    var currentWorkoutSession: HKWorkoutSession?
    var workoutEvents = [HKWorkoutEvent]()


    @IBOutlet var timer: WKInterfaceTimer!

    @IBAction func startMatch() {
        startOrRequestLocationUpdates()

        startWorkout()

        timer.setDate(Date())
        timer.start()
    }

    @IBAction func stopMatch() {
        stopWorkout()

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

    func requestHealthKitAccess() {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }

        let allTypes = Set([HKObjectType.workoutType(),
                            HKObjectType.seriesType(forIdentifier: HKWorkoutRouteTypeIdentifier)!,
                            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
                            HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
                            HKObjectType.quantityType(forIdentifier: .heartRate)!])

        healthStore.requestAuthorization(toShare: allTypes, read: allTypes) { (success, error) in
            if !success, let error = error {
                // Handle the error here.
                print(error.localizedDescription)
            }
        }
    }

    fileprivate func startWorkout() {
        let workoutConfiguration = HKWorkoutConfiguration()

        workoutConfiguration.locationType = .outdoor
        workoutConfiguration.activityType = .soccer

        guard let session = try? HKWorkoutSession(configuration: workoutConfiguration) else {
            return
        }
        session.delegate = self
//        session.startDate = Date()

        currentWorkoutSession = session
        routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: HKDevice.local())

        healthStore.start(session)
    }

    fileprivate func stopWorkout() {
        guard let session = currentWorkoutSession else {
            return
        }

        healthStore.end(session)
    }

    private func saveWorkout() {
        // Create and save a workout sample
        guard let session = currentWorkoutSession else {
            return
        }

        let configuration = session.workoutConfiguration
        let isIndoor = (configuration.locationType == .indoor) as NSNumber
        print("locationType: \(configuration)")

        let workout = HKWorkout(activityType: configuration.activityType,
                                start: session.startDate!,
                                end: session.endDate!,
                                workoutEvents: workoutEvents,
                                totalEnergyBurned: HKQuantity(unit: HKUnit.kilocalorie(), doubleValue: 500),
                                totalDistance: HKQuantity(unit: HKUnit.mile(), doubleValue: 3.1),
                                device: HKDevice.local(),
                                metadata: [HKMetadataKeyIndoorWorkout:isIndoor]);

        healthStore.save(workout) { success, error in
            if success {
                print("Workout Saved.")
                //                self.addSamples(toWorkout: workout)

                self.routeBuilder?.finishRoute(with: workout, metadata: nil) { (newRoute, error) in
                    guard newRoute != nil else {
                        // Handle any errors here.
                        print(error?.localizedDescription ?? "unknown error")
                        return
                    }

                    print("route saved")
                    // Optional: Do something with the route here.

                    self.routeBuilder = nil
                }
            } else {
                print("Unable to save workout: \(String(describing: error?.localizedDescription))")
            }
        }
    }

    fileprivate func startOrRequestLocationUpdates() {
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
            print("Location Auth Status: \(CLLocationManager.authorizationStatus())")
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("\(locations.count) new locations")

        let filteredLocations = locations.filter { (location: CLLocation) -> Bool in
            location.horizontalAccuracy <= 50.0
        }

        guard !filteredLocations.isEmpty else { return }

        // add to workout route?
        routeBuilder?.insertRouteData(filteredLocations) { (success, error) in
            if !success {
                // Handle any errors here.
                print("Route builder: error inserting route data: \(error?.localizedDescription ?? "no error object")")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location: " + error.localizedDescription)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            print("Location: Authorized Always")
        case .notDetermined:
            print("Location: Not Determined: \(status.rawValue)")
            startOrRequestLocationUpdates()
        default:
            print("Location: Not Authorized: \(status.rawValue)")
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
            print("WCSession: " + error.localizedDescription)
        }
    }

//    func sessionDidBecomeInactive(_ session: WCSession) {
//        print("WCSession inactived")
//    }
//
//    func sessionDidDeactivate(_ session: WCSession) {
//        print("WCSession deactived")
//    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
//        print("Workout: " + String(toState.rawValue))

        switch toState {
        case .running:
            if fromState == .notStarted {
                print("starting workout")
//                startAccumulatingData(startDate: workoutStartDate!)
            } else {
                print("resuming workout")
//                resumeAccumulatingData()
            }

        case .paused:
            print("paused workout")
//            pauseAccumulatingData()

        case .ended, .stopped:
            print("stopped workout")
//            stopAccumulatingData()
            saveWorkout()

        default:
            break
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout: " + error.localizedDescription)

        stopWorkout()
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didGenerate event: HKWorkoutEvent) {
        workoutEvents.append(event)
    }


}
