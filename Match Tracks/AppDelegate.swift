//
//  AppDelegate.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/2/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import UIKit
import WatchConnectivity
import Alamofire
import CoreLocation
import CloudKit
import Locksmith

//test comment
//

enum MatchTrackerError: Error {
    case FieldMetadataMissing
    case DirectoryError
    case UnableToUnarchive
    case UnableToParseUUID
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, WCSessionDelegate {
    lazy var locationManager = CLLocationManager()
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.

        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }

        let publicCloudKitDatabase = CKContainer.default().publicCloudDatabase
        let recordID = CKRecord.ID(recordName: "default")

        publicCloudKitDatabase.fetch(withRecordID: recordID) { (record, error) in
            if let keyRecord = record {
                guard let key = keyRecord["apiKey"] as? String else {
                    print("Unable to get APIKey")
                    return
                }

                Environment.API.secretKey = key

                do {
                    try Locksmith.updateData(data: ["apiKey" : key], forUserAccount: "match-tracker")
                } catch {
                    print("unable to save key to keychain")
                }
            } else {
                if let error = error {
                    print(error.localizedDescription)
                }

                //retreive from keychain
                if let key = Locksmith.loadDataForUserAccount(userAccount: "match-tracker")?["apiKey"] as? String {
                    Environment.API.secretKey = key
                }
            }
        }

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        print("Got Session Message: \(message)")
        
        if let shouldRequestLocation = message["requestLocation"] as? Bool, shouldRequestLocation == true {
            DispatchQueue.main.async {
                self.locationManager.requestAlwaysAuthorization()
                self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
            }
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            try Field.saveField(at: file.fileURL, withMetadata: file.metadata)
        } catch MatchTrackerError.FieldMetadataMissing {
            print("Field training metadata is missing")
            return
        } catch {
            debugPrint(error)
            return
        }

        DataSource.default.loadFields()

        DispatchQueue.main.async {
            guard let tabController = self.window?.rootViewController as? UITabBarController,
                let navController = tabController.selectedViewController as? UINavigationController,
                let visibleViewController = navController.visibleViewController else {
                    return
            }

            let alertController = UIAlertController(title: "New Field", message: "Received new field definition", preferredStyle: .alert)

            alertController.addAction(UIAlertAction(title: "Okay", style: .default, handler: { (action) in
                alertController.dismiss(animated: true, completion: nil)
            }))

            visibleViewController.present(alertController, animated: true, completion: nil)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print(error.localizedDescription)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("WCSession inactived")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("WCSession deactived")
    }

}

