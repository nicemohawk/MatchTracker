//
//  FieldsTableViewController.swift
//  MatchTracker
//
//  Created by Ben Lachman on 11/8/18.
//  Copyright © 2018 Nice Mohawk Limited. All rights reserved.
//

import UIKit

//class FieldsTableViewController: UITableViewController {
//    let fieldCellIdentifier = "fieldCell"
//
//    // MARK: - View Lifecycle
//
//    override func viewWillAppear(_ animated: Bool) {
//        DataSource.default.loadFields()
//
//        tableView.reloadData()
//    }
//
//    // MARK: - Datasource
//
//    override func numberOfSections(in tableView: UITableView) -> Int {
//        return 1
//    }
//
//    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
//        return DataSource.default.fields.count
//    }
//
//    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
//        let cell = tableView.dequeueReusableCell(withIdentifier: fieldCellIdentifier, for: indexPath)
//        let field = DataSource.default.fields[indexPath.row]
//
//        cell.textLabel?.text = DateFormatter.localizedString(from: field.timeStamp, dateStyle: .medium, timeStyle: .short)
//        cell.detailTextLabel?.text = "\(field.perimiterDistance) meter perimiter"
//
//        return cell
//    }
//
//    // MARK: - Delegate
//
//    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
//        let field = DataSource.default.fields[indexPath.row]
//        let mapViewController = MapViewController(mappable: field)
//        navigationController?.pushViewController(mapViewController, animated: true)
//    }
//}

class FieldsTableViewController: UITableViewController {
    let fieldCellIdentifier = "ReusableFieldCell"
    let fieldCellNibName = "FieldTableCell"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.register(UINib(nibName: fieldCellNibName, bundle: nil), forCellReuseIdentifier: fieldCellIdentifier)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        //Eventually return number of rows equal to number of data items
        return 5
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        let cell = tableView.dequeueReusableCell(withIdentifier: fieldCellIdentifier, for: indexPath) as! FieldTableCell

        return cell
    }
    
}


