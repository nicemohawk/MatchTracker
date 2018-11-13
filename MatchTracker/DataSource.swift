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

    static let alamofireManager = SessionManager()

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
}
