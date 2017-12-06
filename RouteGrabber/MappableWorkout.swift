//
//  Route.swift
//  RouteGrabber
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
}
