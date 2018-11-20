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
    let uuid: UUID

    init(time: Date, location: CLLocationCoordinate2D, field: [CLLocation], distance: CLLocationDistance, uuid: UUID) {
        self.timeStamp = time
        self.location = location
        self.locations = field
        self.perimiterDistance = distance
        self.uuid = uuid
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

        guard let filenameUUID = UUID(uuidString: dataURL.lastPathComponent) else {
            throw MatchTrackerError.UnableToParseUUID
        }

        self.init(time: time, location: location, field: field, distance: distance, uuid: filenameUUID)
    }

    // MARK: - class methods

    static func directoryURL(for fileURL: URL? = nil) throws -> URL {
        guard let destinationBaseURL = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: fileURL, create: true) else {
            debugPrint("Unable to create destination url for file: \(fileURL?.absoluteString ?? "N/A")")
            throw MatchTrackerError.DirectoryError
        }

        let url = destinationBaseURL.appendingPathComponent("fields")

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)

        return url
    }

    static func saveField(at fileURL: URL, withMetadata metadata: Any?) throws {
        let filename = fileURL.lastPathComponent
        let destinationBaseURL = try self.directoryURL(for: fileURL)

        var documentURL = destinationBaseURL.appendingPathComponent(filename)

        try FileManager.default.moveItem(at: fileURL, to: documentURL)

        guard let metadata = metadata else {
            throw MatchTrackerError.FieldMetadataMissing
        }

        documentURL.appendPathExtension("plist")

        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: documentURL)
    }
}
