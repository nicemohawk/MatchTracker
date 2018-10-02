//
//  DataSource.swift
//  RouteGrabber
//
//  Created by Robert Cantoni on 11/27/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import Foundation
import Alamofire

class DataSource {

    static let alamofireManager = SessionManager()

    func post(workouts: [MappableWorkout], completion: @escaping (_ success: Bool, _ errorMessage: String?) -> Void) {
        DataSource.alamofireManager.request(Router.Workout.post(workouts: workouts))
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
