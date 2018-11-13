//
//  MappableWorkout.swift
//  MatchTracker
//
//  Created by Robert Cantoni on 11/10/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//
import Foundation
import HealthKit
import CoreLocation

struct MappableWorkout {
    var workout: HKWorkout
    var locations: [CLLocation]

    var dictionary: [String: Any]? {
        get {
            // TODO: send up data from HKWorkout that isn't in the CLLocation data

            if locations.count > 0 {
                var dict = [String:Any]()
                var coorinatesArray: [[Double]] = [[Double]]()
                for location in locations {
                    let coordinatePair = [location.coordinate.latitude, location.coordinate.longitude]
                    
                    coorinatesArray.append(coordinatePair)
                }
                
//                if coorinatesArray.count > 10 {
//                    let smallArray: [[Double]] = Array(coorinatesArray[0..<10])
//
//                    coorinatesArray = smallArray
//                }

                dict["track"] = ["coordinates": coorinatesArray]
                let formatter = ISO8601DateFormatter()
                dict["recorded_at"] = formatter.string(from: workout.startDate)

                return dict
            }
            
            print("No locations for this workout")

            return nil
        }
    }
}
