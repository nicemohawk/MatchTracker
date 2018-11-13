//
//  FieldsTableViewController.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/8/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import UIKit

class FieldsTableViewController: UITableViewController {
    let fieldCellIdentifier = "fieldCell"

    var fields = [Field]()


    class func directoryURL(for fileURL: URL? = nil) throws -> URL {
        guard let destinationBaseURL = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: fileURL, create: true) else {
            debugPrint("Unable to create destination url for file: \(fileURL?.absoluteString ?? "N/A")")
            throw MatchTrackerError.DirectoryError
        }

        let url = destinationBaseURL.appendingPathComponent("fields")

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)

        return url
    }

    class func saveField(at fileURL: URL, withMetadata metadata: Any?) throws {
        let filename = fileURL.lastPathComponent
        let destinationBaseURL = try FieldsTableViewController.directoryURL(for: fileURL)

        var documentURL = destinationBaseURL.appendingPathComponent(filename)

        try FileManager.default.moveItem(at: fileURL, to: documentURL)

        guard let metadata = metadata else {
            throw MatchTrackerError.FieldMetadataMissing
        }

        documentURL.appendPathExtension("plist")

        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: documentURL)
    }

    class func loadFields() -> [Field] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: FieldsTableViewController.directoryURL(), includingPropertiesForKeys: [], options: []) else {
            return []
        }

        var files = [String: [String: URL]]()

        for fileURL in urls {
            let uuidString = fileURL.deletingPathExtension().lastPathComponent

            if files[uuidString] == nil {
                files[uuidString] = [String: URL]()
            }

            if fileURL.pathExtension == "" {
                files[uuidString]!["file"] = fileURL
            } else {
                files[uuidString]!["metadata"] = fileURL
            }
        }

        let fields = files.compactMap { (key, value) -> Field? in
            guard let data = value["file"],
                let metaData = value["metadata"] else {
                    return nil
            }

            let aField = try? Field(dataURL: data, metaDataURL: metaData)

            return aField
        }

        return fields
    }

    // MARK: - View Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        fields = FieldsTableViewController.loadFields()

        tableView.reloadData()
    }

    // MARK: - Datasource

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return fields.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: fieldCellIdentifier, for: indexPath)
        let field = fields[indexPath.row]

        cell.textLabel?.text = DateFormatter.localizedString(from: field.timeStamp, dateStyle: .medium, timeStyle: .short)
        cell.detailTextLabel?.text = "\(field.perimiterDistance) meter perimiter"

        return cell
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let field = fields[indexPath.row]
        let mapViewController = MapViewController(mappable: field)
        navigationController?.pushViewController(mapViewController, animated: true)
    }
}
