//
//  ViewController.swift
//  RouteGrabber
//
//  Created by Ben Lachman on 11/2/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import UIKit
import HealthKit
import CoreLocation

class ViewController: UIViewController {

    let healthStore = HKHealthStore()
    var isAuthorized = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.

        let readTypes: Set<HKObjectType> = [HKWorkoutType.workoutType(), HKSeriesType.workoutRoute()]

        healthStore.requestAuthorization(toShare: [], read: readTypes) { (success, error) in
            if success {
                self.isAuthorized = true
            } else {
                self.isAuthorized = false
                print("error authorizating HealthStore. You're propably on iPad \(String(describing: error?.localizedDescription))")
            }
       }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


    @IBAction func getRoutesAction(_ sender: UIButton) {
//        let now = Date()
//        let monthAgo = now - 30*24*60*60

        loadWorkouts { workouts in
            for workout in workouts {
                self.makeWorkoutSlothy(workout)
            }
        }
    }

    func loadWorkouts(completion: @escaping (_ workouts: [HKWorkout]) -> Void) {
        // Query for all workouts created with this app
        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForWorkouts(with: .running)
        let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
            guard let workouts = results as? [HKWorkout] else {
                print("An error occured: \(error?.localizedDescription ?? "Unknown")")
                return
            }

            completion(workouts)
        }

        healthStore.execute(query)
    }

    func makeWorkoutSlothy(_ workout: HKWorkout) {
        // Query for workout's routes
        let routeType = HKSeriesType.workoutRoute()

        let workoutPredicate = HKQuery.predicateForObjects(from: workout)

        let routeQuery = HKSampleQuery(sampleType: routeType, predicate: workoutPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
            guard let route = results?.first as? HKWorkoutRoute else {
                print("An error occured fetching the route: \(error?.localizedDescription ?? "Workout has no routes")")
                return
            }

//            guard let version = route.metadata?[HKMetadataKeySyncVersion] as? NSNumber else {
//                print("Route does not have a sync version for route \(route)")
//                return
//            }

//            if version.intValue == 1 {
                self.makeWorkoutRouteSlothy(workout: nil, route: route)
//            }
        }

        self.healthStore.execute(routeQuery)
    }

    private func makeWorkoutRouteSlothy(workout: HKWorkout?, route: HKWorkoutRoute) {
        // Get all of the locations
        loadRouteLocations(route: route) { locations in
            // Slothify route
            let newLocations = self.slothifyRouteLocations(locations: locations)

//            self.updateWorkoutRoute(workout: workout, route: route, newLocations: newLocations)
        }
    }

    private func loadRouteLocations(route: HKWorkoutRoute, completion: @escaping (_ locations: [CLLocation]) -> Void) {
        var locations = [CLLocation]()

        let locationQuery = HKWorkoutRouteQuery(route: route) { _, locationResults, done, error in
            guard let newLocations = locationResults else {
                print("Error occured while querying for locations: \(error?.localizedDescription ?? "")")
                return
            }
            locations += newLocations

            if done {
                completion(locations)
            }
        }

        healthStore.execute(locationQuery)
    }

    // Slothifying a workout route's locations will shift the locations left and right to form a moving spiral
    // around the original route
    func slothifyRouteLocations(locations: [CLLocation]) -> [CLLocation] {
        var newLocations = [CLLocation]()

        let start = locations.first ?? CLLocation(latitude: 0, longitude: 0)
        newLocations.append(start)

        let radius = 0.0001

        var theta = 0.0
        for i in 1 ..< locations.count - 1 {
            theta += Double.pi / 8
            let dLatitude = sin(theta) * radius
            let dLongitude = cos(theta) * radius

            var coordinate = locations[i].coordinate
            coordinate.latitude += dLatitude
            coordinate.longitude += dLongitude
            let location = CLLocation(coordinate: coordinate,
                                      altitude: locations[i].altitude,
                                      horizontalAccuracy: locations[i].horizontalAccuracy,
                                      verticalAccuracy: locations[i].verticalAccuracy,
                                      course: locations[i].course,
                                      speed: locations[i].speed,
                                      timestamp: locations[i].timestamp)
            newLocations.append(location)
        }

        // Then jump to the last location
        if let lastLocation = locations.last {
            newLocations.append(lastLocation)
        }

        return newLocations
    }
}
