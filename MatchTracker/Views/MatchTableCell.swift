//
//  MatchTableCell.swift
//  MatchTracker
//
//  Created by Eric May on 7/5/21.
//  Copyright © 2021 Nice Mohawk Limited. All rights reserved.
//

import UIKit

class MatchTableCell: UITableViewCell {
    
    @IBOutlet weak var matchView: UIView!
    @IBOutlet weak var matchDateLabel: UILabel!
    @IBOutlet weak var fieldNameAndDateLabel: UILabel!
    
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
}
