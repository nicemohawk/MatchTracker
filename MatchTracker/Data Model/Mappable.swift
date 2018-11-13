//
//  Mappable.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/12/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import UIKit
import CoreLocation

protocol Mappable {
    var locations: [CLLocation] { get }
    var timeStamp: Date { get }
    var dictionary: [String: Any]? { get }
    var bezier: UIBezierPath? { get }
}

extension Mappable {
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
        dict["recorded_at"] = formatter.string(from: timeStamp)

        return dict
        }

        print("No locations for this workout")

        return nil
        }
    }

    var bezier: UIBezierPath? {
        get {
            guard locations.count > 0 else {
                return nil
            }

            let bezier = UIBezierPath()
            bezier.move(to: CGPoint.zero)

            let zerozero = CGPoint(x: locations.first!.coordinate.longitude, y: locations.first!.coordinate.latitude)

            // maybe quad curve with control point being velocity vector (e.g. speed & heading)
            locations.map({ CGPoint(x: $0.coordinate.longitude-Double(zerozero.x), y: $0.coordinate.latitude-Double(zerozero.y)) }).forEach { bezier.addLine(to: $0) }

            return bezier
        }
    }

}
