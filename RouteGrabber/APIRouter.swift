//
//  APIRouter.swift
//  RouteGrabber
//
//  Created by Robert Cantoni on 12/5/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import Foundation
import Alamofire

enum Constants {
    struct API {
        static let serverPrefix = "https://api.jsonbin.io/"
        static let secretKey = "$2a$10$BK8VRQ8.uRRAyPOnfvt3FuomRHiWcOYLN/JkbII73.hY7HzWTOtHW"
        // TODO: keep secret keys out of version control
    }
}

protocol Requestable: URLRequestConvertible {
    var method: HTTPMethod { get }
    var path: String { get }
    var parameters: [String : Any]? { get }
    var parameterEncoding: ParameterEncoding { get }
}

extension Requestable {
    func asURLRequest() throws -> URLRequest {
        let URLString = Constants.API.serverPrefix + self.path

        var mutableRequest = URLRequest(url: URL(string: URLString)!)
        mutableRequest.httpMethod = method.rawValue

        mutableRequest.setValue(Constants.API.secretKey, forHTTPHeaderField: "secret-key")
        mutableRequest.setValue(String(true), forHTTPHeaderField: "private")
        mutableRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        if let params = parameters {
            mutableRequest = try parameterEncoding.encode(mutableRequest, with: params)
        }

        return mutableRequest
    }
}

struct Router {
    enum Workout: Requestable {
        case post(workouts: [MappableWorkout])

        var method: HTTPMethod {
         return .post
        }

        var path: String {
            return "b"
        }
        var parameters: [String : Any]? {
            switch self {
            case .post(let workouts):

                // TODO: send up data from HKWorkout that isn't in the CLLocation data

                var workoutsArray = [[String : Any]]()
                for mappableWorkout in workouts {
                    var locationsArray = [[String : Any]]()
                    for location in mappableWorkout.locations {
                        var coordinateDict = [String : Any]()
                        coordinateDict["latitude"] = location.coordinate.latitude
                        coordinateDict["longitude"] = location.coordinate.longitude

                        var locationDict = [String : Any]()
                        locationDict["coordinate"] = coordinateDict

                        // TODO: Send up all CLLocation data, including the following.
                        // These should work, commented out to simplify debugging

//                        locationDict["altitude"] = location.altitude
//                        locationDict["timestamp"] = String(describing: location.timestamp)
//                        locationDict["speed"] = location.speed
//                        locationDict["course"] = location.course

                        locationsArray.append(locationDict)
                    }

                    var workoutDict = [String : Any]()
                    workoutDict["locations"] = locationsArray
                    workoutsArray.append(workoutDict)
                }

                var parameters = [String : Any]()
                parameters["cllLocations"] = workoutsArray

                return parameters
            }
        }

        var parameterEncoding: ParameterEncoding {
            return JSONEncoding.default
        }
    }
}
