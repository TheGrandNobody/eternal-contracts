//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeFactory.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "../interfaces/IEternalToken.sol";
import "../interfaces/IEternalLiquidity.sol";
import "../inheritances/OwnableEnhanced.sol";

/**
 * @title Eternal automatic liquidity provider contract
 * @author Nobody (me)
 * @notice The Eternal Liquidity provides liquidity for the Eternal Token
 */
contract EternalLiquidity is IEternalLiquidity, OwnableEnhanced {

    // The ETRNL token
    IEternalToken private immutable eternal;
    // Trader Joe Router interface to swap tokens for AVAX and add liquidity
    IJoeRouter02 private immutable joeRouter;
    // The address of the ETRNL/AVAX pair
    address private immutable joePair;

    // Determines whether an auto-liquidity provision process is undergoing
    bool private undergoingSwap;
    // Determines whether the contract is tasked with providing liquidity using part of the transaction fees
    bool private autoLiquidityProvision;

    // Allows contract to receive AVAX tokens
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    constructor (address _eternal) {
        // Initialize router
        IJoeRouter02 _joeRouter= IJoeRouter02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
        joeRouter = _joeRouter;
        // Create pair address
        joePair = IJoeFactory(_joeRouter.factory()).createPair(address(this), _joeRouter.WAVAX());
        // Initialize the Eternal Token
        eternal = IEternalToken(_eternal);
    }

/////–––««« Modifiers »»»––––\\\\\
    /**
     * Ensures the contract doesn't swap when it's already swapping (prevents it from getting caught in a circular liquidity event).
     */
    modifier haltsLiquidityProvision() {
        undergoingSwap = true;
        _;
        undergoingSwap = false;
    }

/////–––««« Variable state-inspection functions »»»––––\\\\\

    /**
     * @dev View the address of the ETRNL/AVAX pair on Trader Joe.
     */
    function viewPair() external view override returns(address) {
        return joePair;
    }

/////–––««« Automatic liquidity provision functions »»»––––\\\\\

    /**
     * @dev Swaps a given amount of ETRNL for AVAX using Trader Joe. (Used for auto-liquidity swaps)
     * @param amount The amount of ETRNL to be swapped for AVAX
     */
    function swapTokensForAVAX(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = joeRouter.WAVAX();

        eternal.approve(address(joeRouter), amount);
        joeRouter.swapExactTokensForAVAXSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    /**
     * @dev Provides liquidity to the ETRNL/AVAX pair on Trader Joe for the EternalToken contract.
     * @param contractBalance The contract's ETRNL balance
     *
     * Requirements:
     * 
     * - Automatic liquidity provision must be enabled
     * - There cannot already be a liquidity swap in progress
     * - Caller can only be the ETRNL contract
     */
    function provideLiquidity(uint256 contractBalance) external override {
        require(_msgSender() == address(eternal), "Only callable by ETRNL contract");
        require(autoLiquidityProvision, "Auto-liquidity is disabled");
        require(!undergoingSwap, "A liquidity swap is in progress");

        _provideLiquidity(contractBalance);
    } 

    /**
     * @dev Converts half the contract's balance to AVAX and adds liquidity to the ETRNL/AVAX pair.
     * @param contractBalance The contract's ETRNL balance
     */
    function _provideLiquidity(uint256 contractBalance) private haltsLiquidityProvision() {
        // Split the contract's balance into two halves
        uint256 half = contractBalance / 2;
        uint256 amountETRNL = contractBalance - half;

        // Capture the initial balance to later compute the difference
        uint256 initialBalance = address(this).balance;
        // Swap half the contract's ETRNL balance to AVAX
        swapTokensForAVAX(half);
        // Compute the amount of AVAX received from the swap
        uint256 amountAVAX = address(this).balance - initialBalance;

        // Add liquidity to the ETRNL/AVAX pair
        eternal.approve(address(joeRouter), amountETRNL);
        joeRouter.addLiquidityAVAX{value: amountAVAX}(address(this), amountETRNL, 0, 0, address(this), block.timestamp);

        emit AutomaticLiquidityProvision(amountETRNL, contractBalance, amountAVAX);
    }

    /**
     * @dev Transfers a given amount of AVAX from the contract to an address. (Admin and Fund only)
     * @param recipient The address to which the AVAX is to be sent
     * @param amount The specified amount of AVAX to transfer
     */
    function withdrawAVAX(address payable recipient, uint256 amount) external override onlyFund() {
        recipient.transfer(amount);

        emit AVAXTransferred(amount, recipient);
    }

    /**
     * @dev Transfers a given amount of ETRNL from the contract to an address. (Admin and Fund only)
     * @param recipient The address to which the ETRNL is to be sent
     * @param amount The specified amount of ETRNL to transfer
     */
    function withdrawETRNL(address recipient, uint256 amount) external override onlyFund() {
        eternal.transfer(recipient, amount);

        emit ETRNLTransferred(amount, recipient);
    }

    /**
     * @dev Determines whether the contract should automatically provide liquidity from part of the transaction fees. (Admin and Fund only)
     * @param value True if automatic liquidity provision is desired. False otherwise.
     */
    function setAutoLiquidityProvision(bool value) external override onlyAdminAndFund() {
        autoLiquidityProvision = value;

        emit AutomaticLiquidityProvisionUpdated(value);
    }
}