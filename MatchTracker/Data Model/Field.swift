//
//  Field.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/9/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import Foundation
import CoreLocation


struct Field: Mappable {
    let timeStamp: Date
    let location: CLLocationCoordinate2D

    let locations: [CLLocation]
    let perimiterDistance: CLLocationDistance

    init(time: Date, location: CLLocationCoordinate2D, field: [CLLocation], distance: CLLocationDistance) {
        self.timeStamp = time
        self.location = location
        self.locations = field
        self.perimiterDistance = distance
    }

    init(dataURL: URL, metaDataURL: URL) throws {
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

        self.init(time: time, location: location, field: field, distance: distance)
    }
}
