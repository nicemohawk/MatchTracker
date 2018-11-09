//
//  FieldTrainingInterfaceController.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/8/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import WatchKit
import WatchConnectivity
import Foundation
import CoreLocation

class FieldTrainingInterfaceController: WKInterfaceController, CLLocationManagerDelegate {
    let locationManager = CLLocationManager()
    var trackingField = false

    lazy var fieldOutline = [CLLocation]()

    var startTime = Date()
    var stopTime = Date()
    var distanceTraveled: CLLocationDistance = 0.0

    @IBOutlet weak var startStopButton: WKInterfaceButton!

    @IBAction func trainField() {
        // start location saving, but no workout.
        if  locationManager.delegate == nil {
            locationManager.delegate = self
        }

        if trackingField == false {
            startTrackingFieldOutline()
            startStopButton.setTitle("Finished")
        } else {
            stopTrackingFieldOutline()
            startStopButton.setTitle("Define Field")
        }
    }

    func startTrackingFieldOutline() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        locationManager.startUpdatingLocation()

        startTime = Date()
        trackingField = true
        distanceTraveled = 0.0

        WKInterfaceDevice.current().play(.stop)
    }

    func stopTrackingFieldOutline() {
        locationManager.stopUpdatingLocation()

        stopTime = Date()
        trackingField = false

        WKInterfaceDevice.current().play(.stop)

        sendFieldData()
    }

    fileprivate func newDistanceTraveled(_ locations: [CLLocation]) -> CLLocationDistance {
        var previousPoint = fieldOutline.last
        var distance = 0.0

        for location in locations {
            guard let point = previousPoint else {
                previousPoint = location
                continue
            }

            distance += location.distance(from: point)
            previousPoint = location
        }

        return distance
    }


    fileprivate func sendFieldData() {
        guard let startingLocation = fieldOutline.first?.coordinate,
        WCSession.default.activationState == .activated else {
            return
        }
//       outline = cleanupOutline()

        guard let url = saveField(outline: fieldOutline) else {
            return
        }

        let metaData: [String : Any] = ["time": startTime, "distance": distanceTraveled, "location": [startingLocation.latitude, startingLocation.longitude]]

        WCSession.default.transferFile(url, metadata: metaData)
    }

    fileprivate func saveField(outline: [CLLocation]) -> URL? {
        let cacheFolderURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = URL(fileURLWithPath: UUID().uuidString, relativeTo: cacheFolderURL)

        if let data = try? NSKeyedArchiver.archivedData(withRootObject: outline, requiringSecureCoding: false) {
            do {
                try data.write(to: url)
            } catch {
                print("unable to save field outline to file")
                return nil
            }
        }

        return url
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        debugPrint("New location update")

        distanceTraveled += newDistanceTraveled(locations)

        fieldOutline.append(contentsOf: locations)

        if let firstLocation = fieldOutline.first,
            let currentLocation = fieldOutline.last,
            distanceTraveled > 50,
            currentLocation.distance(from: firstLocation) < 10.0 {
            // stop if we've arrived back at the same place after traveling more than 50 meters,
            stopTrackingFieldOutline()
        }
    }
}
