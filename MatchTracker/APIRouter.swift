//
//  APIRouter.swift
//  MatchTracker
//
//  Created by Robert Cantoni on 12/5/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import UIKit
import Foundation
import Alamofire
import CloudKit


enum Environment {
    struct API {
        #if RELEASE
        static let serverPrefix = "https://match-tracks.service.nicemohawk.com"
        #else
        static let serverPrefix = "http://10.0.1.10:8080"
        #endif

        static var secretKey = "smarmy"
    }

    static var deviceUUID = UIDevice.current.identifierForVendor
}

protocol Requestable: URLRequestConvertible {
    var method: HTTPMethod { get }
    var path: String { get }
    var parameters: [String : Any]? { get }
    var parameterEncoding: ParameterEncoding { get }
}

extension Requestable {
    var method: HTTPMethod { return .post }
    var port: Int { return Router.port }
    var parameterEncoding: ParameterEncoding { return JSONEncoding.default }

    func asURLRequest() throws -> URLRequest {
        let URLString = Environment.API.serverPrefix + self.path

        var mutableRequest = URLRequest(url: URL(string: URLString)!)
        mutableRequest.httpMethod = method.rawValue

        mutableRequest.setValue("APIKey " + Environment.API.secretKey, forHTTPHeaderField: "Authorization")
        mutableRequest.setValue(String(true), forHTTPHeaderField: "private")
        mutableRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        if let params = parameters {
            mutableRequest = try parameterEncoding.encode(mutableRequest, with: params)
        }

        return mutableRequest
    }
}

struct Router {
    static var device: String {
        return "/devices/\(Environment.deviceUUID?.uuidString ?? "3cb65576-6bfd-4abb-ad23-168b7efda562")"
    }

    static var port: Int {
        return 8080
    }

    enum Fields: Requestable {
        case post(fields: [Field])

        var path: String { return Router.device + "/fields" } // e.g. "/devices/3cb65576-6bfd-4abb-ad23-168b7efda562/fields"

        var parameters: [String : Any]? {
            switch self {
            case .post(let fields):
                var params = [String : Any]()

                guard fields.count > 0 else {
                    print("Nothing to post this time")
                    return nil
                }

                params["fields"] = fields.map { $0.dictionary }

                return params
            }
        }
    }

    enum Sessions: Requestable {
        case post(workouts: [MappableWorkout])

        var path: String { return Router.device + "/sessions" } // e.g. "/devices/3cb65576-6bfd-4abb-ad23-168b7efda562/sessions"
        
        var parameters: [String : Any]? {
            switch self {
            case .post(let workouts):
                var params = [String : Any]()

                guard workouts.count > 0 else {
                    print("No workouts this time")
                    return nil
                }

                params["sessions"] = workouts.map { $0.dictionary }

                return params
            }
        }
    }
}
