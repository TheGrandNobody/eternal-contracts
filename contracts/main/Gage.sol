//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IEternal.sol";
import "../interfaces/IGage.sol";

contract Gage is IGage {

    // Holds all possible statuses for a gage
    enum Status {
        Open,
        Active,
        Closed
    }

    // Holds user-specific information with regards to the gage
    struct UserData {
        address asset;                       // The AVAX address of the asset used as deposit     
        uint256 amount;                      // The entry deposit (in tokens) needed to participate in this gage        
        uint8 risk;                          // The percentage that is being risked in this gage  
        bool inGage;                         // Keeps track of whether the user is in the gage or not
        bool loyalty;                        // Determines whether the gage is a loyalty gage or not
    }

    // The eternal platform
    IEternal public eternal;                

    // Holds all users' information in the gage
    mapping (address => UserData) internal userData;

    // The id of the gage
    uint256 public immutable id;  
    // The maximum number of users in the gage
    uint32 public immutable  capacity; 
    // Keeps track of the number of users left in the gage
    uint32 internal users;
    // The state of the gage       
    Status internal status;         

    constructor (uint256 _id, uint32 _users, address _eternal) {
        id = _id;
        capacity = _users;
        eternal = IEternal(_eternal);
    }      

    /**
     * @dev Adds a stakeholder to this gage and records the initial data.
     * @param asset The address of the asset used as deposit by this user
     * @param amount The user's chosen deposit amount 
     * @param risk The user's chosen risk percentage
     * @param loyalty Whether the gage is a loyalty gage
     *
     * Requirements:
     *
     * - Risk must not exceed 100 percent
     * - User must not already be in the gage
     */
    function join(address asset, uint256 amount, uint8 risk, bool loyalty) external override {
        require(risk <= 100, "Invalid risk percentage");
        UserData storage data = userData[msg.sender];
        require(!data.inGage, "User is already in this gage");

        data.amount = amount;
        data.asset = asset;
        data.risk = risk;
        data.inGage = true;
        data.loyalty = loyalty;
        users += 1;

        eternal.deposit(asset, msg.sender, amount, id);
        emit UserAdded(id, msg.sender);
        // If contract is filled, update its status and initiate the gage
        if (users == capacity) {
            status = Status.Active;
            emit GageInitiated(id);
        }
    }

    /**
     * @dev Removes a stakeholder from this gage.
     *
     * Requirements:
     *
     * - User must be in the gage
     */
    function exit() external override {
        UserData storage data = userData[msg.sender];
        require(data.inGage, "User is not in this gage");
        
        // Remove user from the gage first (prevent re-entrancy)
        data.inGage = false;

        if (status != Status.Closed) {
            users -= 1;
            emit UserRemoved(id, msg.sender);
        }

        if (status == Status.Active && users == 1) {
            // If there is only one user left after this one has left, update the gage's status accordingly
            status = Status.Closed;
            emit GageClosed(id);
        }

        eternal.withdraw(msg.sender, id);
    }

    /////–––««« Variable state-inspection functions »»»––––\\\\\

    /**
     * @dev View the number of stakeholders in the gage (if it isn't yet active)
     * @return The number of stakeholders in the selected gage
     *
     * Requirements:
     *
     * - Gage status cannot be 'Active'
     */
    function viewGageUserCount() external view override returns (uint32) {
        require(status != Status.Active, "Gage can't be active");
        return users;
    }

    /**
     * @dev View the total user capacity of the gage
     * @return The total user capacity
     */
    function viewCapacity() external view override returns(uint256) {
        return capacity;
    }

    /**
     * @dev View the status of the gage
     * @return An integer indicating the status of the gage
     */
    function viewStatus() external view override returns (uint) {
        return uint(status);
    }

    /**
     * @dev View a given user's gage data 
     * @param user The address of the specified user
     * @return The asset, amount and risk for this user 
     */
    function viewUserData(address user) external view override returns (address, uint256, uint256, bool){
        UserData storage data = userData[user];
        return (data.asset, data.amount, data.risk, data.loyalty);
    }
}