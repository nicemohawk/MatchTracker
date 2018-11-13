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

struct MappableWorkout: Mappable {
    var workout: HKWorkout
    var locations: [CLLocation]

    var timeStamp: Date {
        get {
            return workout.startDate
        }
    }

}
