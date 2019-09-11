//
//  WorkoutInterfaceController.swift
//  Match Tracker Extension
//
//  Created by Ben Lachman on 9/28/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import WatchKit
import Foundation
import CoreLocation
import HealthKit


class WorkoutInterfaceController: WKInterfaceController {
    var workoutController: WorkoutController = WorkoutController.shared

    @IBOutlet weak var elapsedTimer: WKInterfaceTimer!
    @IBOutlet weak var distanceLabel: WKInterfaceLabel!
    @IBOutlet weak var caloriesLabel: WKInterfaceLabel!
    @IBOutlet weak var heartRateLabel: WKInterfaceLabel!


    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        
        workoutController.startWorkout(withContext: context)
        
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            self.updateLabels()
            self.setElapsedTimerDate()
        }
    }

    override func willActivate() {
        // This method is called when watch view controller is about to be visible to user
        super.willActivate()

        workoutController.startOrRequestLocationUpdates()
        
        setTitle("")
    }

    override func didDeactivate() {
        // This method is called when watch view controller is no longer visible
        super.didDeactivate()
    }

    static func closeWorkoutDisplay() {
        DispatchQueue.main.async {
            WKInterfaceController.reloadRootPageControllers(withNames: ["TrainField","StartMatch"], contexts: nil, orientation: .vertical, pageIndex: 1)
        }
    }

    override func didAppear() {
        super.didAppear()
    }

    // MARK: - Custom functions
    
    func updateLabels() {
        let formatter = MeasurementFormatter()
        formatter.numberFormatter.maximumFractionDigits = 2
        
        heartRateLabel.setText(formatter.numberFormatter.string(from: NSNumber(value:workoutController.workoutMetrics.bpm)))
        
        formatter.unitOptions = [.providedUnit]
        formatter.numberFormatter.maximumFractionDigits = 0
        caloriesLabel.setText(formatter.string(from: workoutController.workoutMetrics.cal))
        
        distanceLabel.setText(formatter.string(from: workoutController.workoutMetrics.distance))
    }
    
    func setElapsedTimerDate() {
        let elapesedTimeStartDate = Date(timeInterval: -workoutController.workoutBuilder.elapsedTime, since: Date())
        let sessionState = workoutController.workoutSession.state

        DispatchQueue.main.async {
            self.elapsedTimer.setDate(elapesedTimeStartDate)
            
            if sessionState == .running {
                self.elapsedTimer.start()
                print("start timer")
            } else {
                self.elapsedTimer.stop()
                print("stop timer")
            }
        }
    }
}

