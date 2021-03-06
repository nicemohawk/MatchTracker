//
//  RoutesTableViewController.swift
//  MatchTracker
//
//  Created by Robert Cantoni on 11/7/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import UIKit
import HealthKit
import CoreLocation

class MatchesTableViewController: UITableViewController {

    let healthStore = HKHealthStore()
    var isAuthorized = false

    let routeCellIdentifier = "routeCellIdentifier"

    // MARK: - UIView lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        requestHealthKitAccess()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        getRoutes()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return DataSource.default.workouts.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: routeCellIdentifier, for: indexPath)

        // add basic route info to the cell
        let workout = DataSource.default.workouts[indexPath.row]
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        cell.textLabel?.text = dateFormatter.string(from: workout.workout.startDate)
        cell.detailTextLabel?.text = "\(workout.locations.count) locations"

        return cell
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 88.0
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let workout = DataSource.default.workouts[indexPath.row]
        let mapViewController = MapViewController(mappable: workout)
        navigationController?.pushViewController(mapViewController, animated: true)
    }

    /*
     // MARK: - Navigation

     // In a storyboard-based application, you will often want to do a little preparation before navigation
     override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
     // Get the new view controller using segue.destinationViewController.
     // Pass the selected object to the new view controller.
     }
     */

    // MARK: - Getting Routes

    @IBAction func updateTableView() {
        guard DataSource.default.workouts.count > 0 else {
            return
        }

        let workout = DataSource.default.workouts[0]
        if let oneLocation = workout.locations.first {
            print("We found a location: \(oneLocation)")
        }

        DataSource.default.post(mappable: [workout]) { (success, error) in
            self.tableView.reloadData()
        }
    }

    @IBAction func getRoutes() {
        DataSource.default.workouts = [MappableWorkout]()

        loadWorkouts { workouts in
            for workout in workouts {
                // get route from workout
                self.findRoute(workout: workout, completion: { route in
                    // get locations
                    self.loadRouteLocations(route: route, completion: { locations in
                        let newMappableWorkout = MappableWorkout(workout: workout, locations: locations)
                        DataSource.default.workouts.append(newMappableWorkout)

                        DispatchQueue.main.async {
                            self.tableView.reloadData()
                        }
                    })
                })
            }
        }
    }

    func loadWorkouts(completion: @escaping (_ workouts: [HKWorkout]) -> Void) {
        // Query for all workouts

        let workoutType = HKObjectType.workoutType()
        let predicate = HKQuery.predicateForWorkouts(with: .soccer)
        let dateSortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [dateSortDescriptor]) { _, results, error in
            guard let workouts = results as? [HKWorkout] else {
                print("An error occured: \(error?.localizedDescription ?? "Unknown")")
                return
            }

            completion(workouts)
        }

        healthStore.execute(query)
    }

    func findRoute(workout: HKWorkout, completion: @escaping (_ route: HKWorkoutRoute) -> Void) {
        // Query for workout's routes

        let routeType = HKSeriesType.workoutRoute()
        let workoutPredicate = HKQuery.predicateForObjects(from: workout)


        let routeQuery = HKSampleQuery(sampleType: routeType, predicate: workoutPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
            guard let routes = results as? [HKWorkoutRoute] else {
                print("An error occured fetching the route: \(error?.localizedDescription ?? "Workout has no routes")")
                return
            }

            //            print("We found at least one route")

            for route in routes {
                completion(route)
            }
        }

        self.healthStore.execute(routeQuery)
    }

    private func loadRouteLocations(route: HKWorkoutRoute, completion: @escaping (_ locations: [CLLocation]) -> Void) {
        // query healthkit for CLLocations from route data
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

    let readTypes: Set<HKSampleType> = Set( [HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
                                             HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
                                             HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
                                             HKObjectType.quantityType(forIdentifier: .heartRate)!] )
    let shareTypes: Set<HKSampleType> = Set( [HKObjectType.workoutType(),
                                              HKObjectType.seriesType(forIdentifier: HKWorkoutRouteTypeIdentifier)!] )

    func requestHealthKitAccess() {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }

        let allTypes = readTypes.union(shareTypes)

        healthStore.requestAuthorization(toShare: shareTypes, read: allTypes) { (success, error) in
            guard success else {
                // Handle the error here.
                print("Error authorizating HealthStore \(String(describing: error?.localizedDescription))")
                self.isAuthorized = false
                return
            }

            self.isAuthorized = true
        }
    }
}
