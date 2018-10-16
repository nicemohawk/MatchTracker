//
//  MapViewController.swift
//  MatchTracker
//
//  Created by Robert Cantoni on 11/10/17.
//  Copyright © 2017 Nice Mohawk Limited. All rights reserved.
//

import UIKit
import MapKit

class MapViewController: UIViewController, MKMapViewDelegate {

    let mapView = MKMapView()
    let mappableWorkout: MappableWorkout

    init(mappableWorkout: MappableWorkout) {
        self.mappableWorkout = mappableWorkout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.mapType = .hybrid
        view.addSubview(mapView)

        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])

        // convert our CLLocations to CLLocationCoordinate2D
        var locationCoordinates = [CLLocationCoordinate2D]()
        for location in mappableWorkout.locations {
            locationCoordinates.append(location.coordinate)
        }

        // add to MKPolyline for display
        let overlay = MKPolyline(coordinates: locationCoordinates, count: locationCoordinates.count)
        mapView.addOverlay(overlay, level: .aboveRoads)

        // rough map zoom
        let span = MKCoordinateSpan.init(latitudeDelta: 0.01, longitudeDelta: 0.01)
        let region = MKCoordinateRegion.init(center: mappableWorkout.locations[0].coordinate, span: span)
        mapView.setRegion(region, animated: false)
    }

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */


    // MARK: - Map View Delegate Methods

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {

        if overlay.isKind(of: MKPolyline.self) {
            // use MKOverlayPathRenderer for display -- TODO: subclass to add curves
            let overlayRenderer =  MKPolylineRenderer(overlay: overlay)

            overlayRenderer.strokeColor = UIColor.purple
            overlayRenderer.lineWidth = 4.0

            return overlayRenderer
        }

        return MKOverlayRenderer()
    }
}





















