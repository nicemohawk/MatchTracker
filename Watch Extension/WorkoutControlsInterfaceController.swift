//
//  WorkoutControlsInterfaceController.swift
//  Match Tracker Extension
//
//  Created by Ben Lachman on 9/11/19.
//  Copyright © 2019 Nice Mohawk Limited. All rights reserved.
//

import WatchKit

class WorkoutControlsInterfaceController: WKInterfaceController {
    let workoutController = WorkoutController.shared
    
    @IBAction func pauseResume() {
        workoutController.pauseResumeWorkout()
    }
    
    @IBAction func stopWorkout() {
        workoutController.stopWorkout {
            WorkoutInterfaceController.closeWorkoutDisplay()
        }
    }
}
