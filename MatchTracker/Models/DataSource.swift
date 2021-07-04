//
//  DataSource.swift
//  MatchTracker
//
//  Created by Robert Cantoni on 11/27/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import Foundation
import Alamofire

class DataSource {
    static let `default` = DataSource()
    static let alamofireManager = SessionManager()

    var fields: [Field]
    var workouts: [MappableWorkout]

    private init() {
        fields = [Field]()
        workouts = [MappableWorkout]()
    }

    // MARK: - Network Aceess

    func post(mappable: [Mappable], completion: @escaping (_ success: Bool, _ errorMessage: String?) -> Void) {
        let requestable: Requestable

        switch mappable {
        case let fields where fields is [Field]:
            requestable = Router.Fields.post(fields: (fields as! [Field]))
        case let workouts where workouts is [MappableWorkout]:
            requestable = Router.Sessions.post(workouts: (workouts as! [MappableWorkout]))
        default:
            completion(false, "No request handler for \(type(of: mappable))" )
            return
        }

        DataSource.alamofireManager.request(requestable)
            .validate()
            .responseJSON { response -> Void in
                switch response.result {
                case .success(let value):
                    print("Success with result: \(value)")
                    completion(true, nil)
                case .failure(let error):
                    print("error sending workouts: \(error)")
                    completion(false, error.localizedDescription)
                }
        }
    }

    func upload(newFields: [Field]) {
        DataSource.default.post(mappable: fields) { (success, errorMessage) in
            if let message = errorMessage, message.count > 0 {
                print("POST error: \(message)")
            }
        }
    }

    // MARK: - Data Methods

    func loadFields() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: Field.directoryURL(), includingPropertiesForKeys: [], options: []) else {
            self.fields = [Field]()
            return
        }

        var files = [String: [String: URL]]()

        for fileURL in urls {
            guard let uuid = UUID(uuidString: fileURL.deletingPathExtension().lastPathComponent),
                self.fields.first(where: { $0.uuid == uuid }) == nil else {
                    continue
            }


            if files[uuid.uuidString] == nil {
                files[uuid.uuidString] = [String: URL]()
            }

            if fileURL.pathExtension == "" {
                files[uuid.uuidString]!["file"] = fileURL
            } else {
                files[uuid.uuidString]!["metadata"] = fileURL
            }
        }

        let newFields = files.compactMap { (key, value) -> Field? in
            guard let data = value["file"],
                let metaData = value["metadata"] else {
                    return nil
            }

            let aField = try? Field(dataURL: data, metaDataURL: metaData)

            return aField
        }

        upload(newFields: newFields)

        self.fields.append(contentsOf: newFields)
    }
}
