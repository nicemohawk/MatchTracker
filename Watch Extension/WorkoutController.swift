//
//  WorkoutController.swift
//  Match Tracker Extension
//
//  Created by Ben Lachman on 9/11/19.
//  Copyright © 2019 Nice Mohawk Limited. All rights reserved.
//

import WatchKit
import CoreLocation
import HealthKit

struct WorkoutMetrics {
    var bpm: Double = 0
    var cal: Measurement<UnitEnergy>
    var distance: Measurement<UnitLength>
}

class WorkoutController: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, CLLocationManagerDelegate {
    static let shared = WorkoutController()

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

    // MARK: - Actions
    
    func startWorkout(withContext context: Any?) {
        startOrRequestLocationUpdates()
        
        if let session = context as? HKWorkoutSession {
            workoutSession = session
        } else {
            do {
                workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: workoutConfiguration)
            } catch {
                WorkoutInterfaceController.closeWorkoutDisplay()
                return
            }
        }
        workoutSession.delegate = self
        
        workoutBuilder = workoutSession.associatedWorkoutBuilder()
        workoutBuilder.delegate = self
        workoutBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: workoutConfiguration)
        
        workoutSession.startActivity(with: Date())
        
        workoutBuilder.beginCollection(withStart: Date(), completion: { (success, error) in
//            self.setElapsedTimerDate()
            
            if success {
                print("began collection")
            } else {
                print("stop activity")
                self.workoutSession.stopActivity(with: Date())
                self.workoutSession.end()
                
                if let error = error {
                    print(error.localizedDescription)
                }
                
                WorkoutInterfaceController.closeWorkoutDisplay()
            }
        })
    }
    
    func pauseResumeWorkout() {
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
    
    func stopWorkout(completion: (()->Void)) {
        DispatchQueue.main.async {
            self.locationManager.stopUpdatingLocation()
        }
        
        workoutSession.end()
        
        guard workoutBuilder.elapsedTime > 60 else {
            workoutBuilder.discardWorkout()
            completion()
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
        
        completion()
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
    
    func startOrRequestLocationUpdates() {
        self.locationManager.delegate = self

        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways:
            DispatchQueue.main.async {
                self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
                self.locationManager.startUpdatingLocation()
            }
        case .notDetermined:
            DispatchQueue.main.async {
                self.locationManager.requestAlwaysAuthorization()
                self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
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
                updateMetrics(forType: quantityType, withStatistics: stats)
            }
        }
    }
    
    var workoutMetrics = WorkoutMetrics(bpm: 0, cal: Measurement<UnitEnergy>(value: 0, unit: .calories), distance: Measurement<UnitLength>(value: 0, unit: .miles))
    
    func updateMetrics(forType quantityType: HKQuantityType, withStatistics statistics: HKStatistics ) {
        debugPrint("\(quantityType.identifier) update")
        
        let calories = HKUnit.largeCalorie()
        let distance = HKUnit.meter()
        let bpm = HKUnit.count().unitDivided(by: HKUnit.minute())
        
        switch quantityType.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            if let bpm = statistics.mostRecentQuantity()?.doubleValue(for: bpm), bpm > 1 {
                workoutMetrics.bpm = bpm
            }
            
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            let measurement = Measurement(value: statistics.sumQuantity()!.doubleValue(for: calories), unit: UnitEnergy.calories)
            workoutMetrics.cal = measurement
            
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            let measurement = Measurement(value: statistics.sumQuantity()!.doubleValue(for: distance), unit: UnitLength.meters)
            workoutMetrics.distance = measurement
            
        default:
            break
        }
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
//        setElapsedTimerDate()
    }
    
    // MARK: - HKWorkoutSessionDelegate
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
//        setElapsedTimerDate()
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout Sesstion failed with error: \(error.localizedDescription)")
    }
}
