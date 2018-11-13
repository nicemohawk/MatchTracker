//
//  Field.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/9/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import Foundation
import CoreLocation


class Field {
    let time: Date
    let location: CLLocationCoordinate2D

    let outline: [CLLocation]
    let perimiterDistance: CLLocationDistance

    required init(time: Date, location: CLLocationCoordinate2D, outline: [CLLocation], distance: CLLocationDistance) {
        self.time = time
        self.location = location
        self.outline = outline
        self.perimiterDistance = distance
    }

    convenience init(dataURL: URL, metaDataURL: URL) throws {
        let locationData = try Data(contentsOf: dataURL)

        guard let field = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(locationData) as? [CLLocation] else {
            throw MatchTrackerError.UnableToUnarchive
        }

        let data = try Data(contentsOf: metaDataURL)

        guard let metadata = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw MatchTrackerError.FieldMetadataMissing
        }

        guard let time = metadata["time"] as? Date,
            let locationCoordinates = metadata["location"] as? Array<Double>,
            let distance = metadata["distance"] as? CLLocationDistance else {
                throw MatchTrackerError.FieldMetadataMissing
        }

        let location = CLLocationCoordinate2D(latitude: locationCoordinates[0], longitude: locationCoordinates[1])

        self.init(time: time, location: location, outline: field, distance: distance)
    }
}
