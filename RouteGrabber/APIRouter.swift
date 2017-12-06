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

                // debug
                // just send up the first workout with its first location coordinate


                if workouts.count > 0 {
                    let workout = workouts[0]
                    if workout.locations.count > 0 {
                        var locationsArray: [[String : Any]] = [[String : Any]]()
                        for location in workout.locations {
                            var coordinateDict = [String : Any]()
                            coordinateDict["latitude"] = location.coordinate.latitude
                            coordinateDict["longitude"] = location.coordinate.longitude

                            var locationDict = [String : Any]()
                            locationDict["coordinate"] = coordinateDict

                            locationsArray.append(locationDict)
                        }

//                        let location = workout.locations[0]
//
//                        var coordinateDict = [String : Any]()
//                        coordinateDict["latitude"] = location.coordinate.latitude
//                        coordinateDict["longitude"] = location.coordinate.longitude
//                        return coordinateDict
//                        locationsArray.append(coordinateDict)

                        print("Number of locations: \(locationsArray.count)")
                        // 1299 > x > 1300
                        let smallerLocationsArray: [[String : Any]] = Array(locationsArray[0..<1301])

                        print("Sending up locations: \(smallerLocationsArray) \n Done listing locations before sendoff")

                        var params = [String : Any]()
                        params["locations"] = smallerLocationsArray
                        return params


                    } else {
                        print("No locations this time")
                    }

                } else {
                    print("No workouts this time")
                }



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
//                parameters["cllLocations"] = workoutsArray
                parameters["data"] = "hello world"

                return parameters
            }
        }

        var parameterEncoding: ParameterEncoding {
            return JSONEncoding.default
        }
    }
}
