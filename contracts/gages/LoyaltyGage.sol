//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Gage.sol";
import "../interfaces/ILoyaltyGage.sol";

/**
 * @title Loyalty Gage contract
 * @author Nobody (me)
 * @notice A loyalty gage creates a healthy, symbiotic relationship between a distributor and a receiver
 */
contract LoyaltyGage is Gage, ILoyaltyGage {

/////–––««« Variables: Addresses and Interfaces »»»––––\\\\\

    // Address of the stakeholder which pays the discount in a loyalty gage
    address public immutable distributor;
    // Address of the stakeholder which benefits from the discount in a loyalty gage
    address public immutable receiver;
    // The asset used in the condition
    IERC20 private assetOfReference;

/////–––««« Variables: Condition computation »»»––––\\\\\

    // The percentage change condition for the total token supply (x 10 ** 11)
    uint256 public immutable percent;
    // The total supply at the time of the deposit
    uint256 private totalSupply;
    // Whether the token's supply is inflationary or deflationary
    bool public immutable inflationary;

/////–––««« Constructors & Initializers »»»––––\\\\\

    constructor(uint256 _id, uint256 _percent, uint256 _users, bool _inflationary, address _distributor, address _receiver, address _storage) Gage(_id, _users, _storage, true) {
        distributor = _distributor;
        receiver = _receiver;
        percent = _percent;
        inflationary = _inflationary;
    }
/////–––««« Variable state-inspection functions »»»––––\\\\\

    /**
     * @notice View the target supply plus/minus the percent change condition for the total token supply of the asset of reference.
     * @return uint256 The minimum target supply which meets the percent change condition
     */
    function viewTarget() public view override returns (uint256) {
        uint256 delta = (totalSupply * percent / (10 ** 11));
        return inflationary ? totalSupply + delta : totalSupply - delta;
    }
    
/////–––««« Gage-logic functions »»»––––\\\\\
    /**
     * @notice Initializes a loyalty gage for the receiver and distributor.
     * @param rAsset The address of the asset used as deposit by the receiver
     * @param dAsset The address of the asset used as deposit by the distributor
     * @param rAmount The receiver's chosen deposit amount 
     * @param dAmount The distributor's chosen deposit amount
     * @param rRisk The receiver's risk
     * @param dRisk The distributor's risk
     *
     * Requirements:
     *
     * - Only callable by an Eternal contract
     */
    function initialize(address rAsset, address dAsset, uint256 rAmount, uint256 dAmount, uint256 rRisk, uint256 dRisk) external override {
        bytes32 entity = keccak256(abi.encodePacked(address(eternalStorage)));
        bytes32 sender = keccak256(abi.encodePacked(_msgSender()));
        require(_msgSender() == eternalStorage.getAddress(entity, sender), "msg.sender must be from Eternal");

        treasury = IEternalTreasury(_msgSender());

        // Save receiver parameters and data
        userData[receiver].inGage = true;
        userData[receiver].amount = rAmount;
        userData[receiver].asset = rAsset;
        userData[receiver].risk = rRisk;

        // Save distributor parameters and data
        userData[distributor].inGage = true;
        userData[distributor].amount = dAmount;
        userData[distributor].asset = dAsset;
        userData[distributor].risk = dRisk;

        // Save liquid gage parameters
        assetOfReference = IERC20(dAsset);
        totalSupply = assetOfReference.totalSupply();

        users = 2;

        status = Status.Active;
        emit GageInitiated(id);
    }

    /**
     * @notice Closes this gage and determines the winner.
     *
     * Requirements:
     *
     * - Only callable by the receiver
     * - Gage must be active
     */
    function exit() external override {
        require(_msgSender() == receiver, "Only the receiver may exit");
        require(status == Status.Active, "Cannot exit an inactive gage");
        // Remove user from the gage first (prevent re-entrancy)
        userData[receiver].inGage = false;
        userData[distributor].inGage = false;
        // Calculate the target supply after the change in total supply of the asset of reference
        uint256 targetSupply = viewTarget();
        // Determine whether the user is the winner
        bool winner = inflationary ? assetOfReference.totalSupply() >= targetSupply : assetOfReference.totalSupply() <= targetSupply;
        emit GageClosed(id, winner ? receiver : distributor);
        status = Status.Closed;
        // Communicate with an external treasury which offers gages
        treasury.settleGage(receiver, id, winner);
    }
}