//
//  WorkoutInterfaceController.swift
//  Match Tracker Extension
//
//  Created by Ben Lachman on 9/28/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import WatchKit
import Foundation
import CoreLocation
import HealthKit


class WorkoutInterfaceController: WKInterfaceController, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, CLLocationManagerDelegate {

    @IBOutlet weak var elapsedTimer: WKInterfaceTimer!
    @IBOutlet weak var distanceLabel: WKInterfaceLabel!
    @IBOutlet weak var caloriesLabel: WKInterfaceLabel!
    @IBOutlet weak var heartRateLabel: WKInterfaceLabel!

    let locationManager = CLLocationManager()
    let healthStore = HKHealthStore()

    lazy var routeBuilder: HKWorkoutRouteBuilder = {
        return HKWorkoutRouteBuilder(healthStore: healthStore, device: HKDevice.local())
    }()

    lazy var workoutConfiguration: HKWorkoutConfiguration = {
        let configuration = HKWorkoutConfiguration()

        configuration.locationType = .outdoor
        configuration.activityType = .soccer

        return configuration
    }()

    var workoutSession: HKWorkoutSession!
    var workoutBuilder: HKLiveWorkoutBuilder!


    override func awake(withContext context: Any?) {
        super.awake(withContext: context)

        startOrRequestLocationUpdates()

        if let session = context as? HKWorkoutSession {
            workoutSession = session
        } else {
            do {
                workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: workoutConfiguration)
            } catch {
                self.closeWorkoutDisplay()
                return
            }
        }
        workoutSession.delegate = self

        workoutBuilder = workoutSession.associatedWorkoutBuilder()
        workoutBuilder.delegate = self
        workoutBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: workoutConfiguration)

        workoutSession.startActivity(with: Date())

        workoutBuilder.beginCollection(withStart: Date(), completion: { (success, error) in
            self.setElapsedTimerDate()

            if success {
                print("began collection")
            } else {
                print("stop activity")
                self.workoutSession.stopActivity(with: Date())
                self.workoutSession.end()

                if let error = error {
                    print(error.localizedDescription)
                }

                self.closeWorkoutDisplay()
            }
        })
    }

    override func willActivate() {
        // This method is called when watch view controller is about to be visible to user
        super.willActivate()

        DispatchQueue.main.async {
            self.locationManager.delegate = self
            self.locationManager.requestAlwaysAuthorization()
            self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        setTitle("")
    }

    override func didDeactivate() {
        // This method is called when watch view controller is no longer visible
        super.didDeactivate()
    }

    override func didAppear() {
        super.didAppear()
    }

    @IBAction func pauseResume() {
        if workoutSession.state == .running {
            workoutSession.pause()

            // TODO: should we stop location tracking here, or just stop recording it?
            DispatchQueue.main.async {
                self.locationManager.stopUpdatingLocation()
            }
        } else {
            workoutSession.resume()
            DispatchQueue.main.async {
                self.locationManager.startUpdatingLocation()
            }
        }
    }

    @IBAction func stopWorkout() {
        DispatchQueue.main.async {
            self.locationManager.stopUpdatingLocation()
        }

        workoutSession.end()

        guard workoutBuilder.elapsedTime > 60 else {
            workoutBuilder.discardWorkout()
            self.closeWorkoutDisplay()
            return
        }

        workoutBuilder.endCollection(withEnd: Date()) { (success, error) in
            if success {
                self.workoutBuilder.finishWorkout { (workout, error) in

                    if let workout = workout {
                        print("Workout completed: \(workout)")

                        self.finishRoute(forWorkout: workout)
                    } else if let error = error {
                        print("Error finishing workout: \(error.localizedDescription)")
                    }
                }
            } else {
                print("not successful")
            }

            if let error = error {
                print("Error ending collection: \(error.localizedDescription)")
            }
        }

        self.closeWorkoutDisplay()
    }

    func closeWorkoutDisplay() {
        DispatchQueue.main.async {
            WKInterfaceController.reloadRootPageControllers(withNames: ["TrainField","StartMatch"], contexts: nil, orientation: .vertical, pageIndex: 1)
        }
    }
    
    func setElapsedTimerDate() {
        let elapesedTimeStartDate = Date(timeInterval: -workoutBuilder.elapsedTime, since: Date())
        let sessionState = workoutSession.state

        DispatchQueue.main.async {
            self.elapsedTimer.setDate(elapesedTimeStartDate)
            
            if sessionState == .running {
                self.elapsedTimer.start()
                print("start timer")
            } else {
                self.elapsedTimer.stop()
                print("stop timer")
            }
        }
    }


    // MARK: - Route/Location tracking

    fileprivate func finishRoute(forWorkout workout: HKWorkout) {
        DispatchQueue.main.async {
            self.stopLocationUpdates()
        }

        // discard() the routebuilder empty data somewhere here?

        routeBuilder.finishRoute(with: workout, metadata: nil) { (newRoute, error) in
            guard newRoute != nil else {
                // Handle any errors here.
                print("Finish route: \(error?.localizedDescription ?? "unknown error while saving workout route")")
                return
            }

            // Optional: Do something with the route here.
            print("route saved")
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

//            if WCSession.default.isReachable {
//                WCSession.default.sendMessage(["requestLocation": true], replyHandler: nil) { (error) in
//                    print(error.localizedDescription)
//                }
//            }
        default:
            print("Location Auth Status: \(CLLocationManager.authorizationStatus())")
        }
    }

    fileprivate func stopLocationUpdates() {
        self.locationManager.stopUpdatingLocation()

        print("stopped updating locations")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("\(locations.count) new locations")

        let filteredLocations = locations.filter { (location: CLLocation) -> Bool in
            location.horizontalAccuracy <= 50.0
        }

        guard !filteredLocations.isEmpty else { return }

        print(filteredLocations)
        // add to workout route?
        routeBuilder.insertRouteData(filteredLocations) { (success, error) in
            if success {
                print("Inserted \(filteredLocations.count) locations")
            } else {
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

    // MARK: - HKLiveWorkoutBuilderDelegate

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType else {
                continue
            }

            if let stats = workoutBuilder.statistics(for: quantityType) {
                updateLabel(forType: quantityType, withStatistics: stats)
            }
        }
    }

    func updateLabel(forType quantityType: HKQuantityType, withStatistics statistics: HKStatistics ) {
        debugPrint("\(quantityType.identifier) update")

        let formatter = MeasurementFormatter()
        formatter.numberFormatter.maximumFractionDigits = 2
        let calories = HKUnit.largeCalorie()
        let miles = HKUnit.mile()
        let bpm = HKUnit.count().unitDivided(by: HKUnit.minute())

        switch quantityType.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            if let bpm = statistics.mostRecentQuantity()?.doubleValue(for: bpm), bpm > 1 {
                heartRateLabel.setText(formatter.numberFormatter.string(from: NSNumber(value:bpm)))
            }

        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            let measurement = Measurement(value: statistics.sumQuantity()!.doubleValue(for: calories), unit: UnitEnergy.calories)

            formatter.unitOptions = [.providedUnit]
            formatter.numberFormatter.maximumFractionDigits = 0
            caloriesLabel.setText(formatter.string(from: measurement))

        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            let measurement = Measurement(value: statistics.sumQuantity()!.doubleValue(for: miles), unit: UnitLength.miles)
            distanceLabel.setText(formatter.string(from: measurement))

        default:
            break
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        setElapsedTimerDate()
    }

    // MARK: - HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        setElapsedTimerDate()
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout Sesstion failed with error: \(error.localizedDescription)")
    }

}
