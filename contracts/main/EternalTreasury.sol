//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "../inheritances/OwnableEnhanced.sol";
import "../interfaces/IEternalFactory.sol";
import "../interfaces/IEternalTreasury.sol";
import "../interfaces/IEternalStorage.sol";
import "../interfaces/ILoyaltyGage.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeFactory.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoePair.sol";
import "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IWAVAX.sol";

/**
 * @title Contract for the Eternal Treasury
 * @author Nobody (me)
 * @notice The Eternal Treasury contract holds all treasury logic
 */
 contract EternalTreasury is IEternalTreasury, OwnableEnhanced {

/////–––««« Variables: Interfaces, Addresses and Hashes »»»––––\\\\\

    // The Trader Joe router interface
    IJoeRouter02 public immutable joeRouter;
    // The Trader Joe factory interface
    IJoeFactory public immutable joeFactory;
    // The Eternal shared storage interface
    IEternalStorage public immutable eternalStorage;
    // The Eternal factory interface
    IEternalFactory private eternalFactory;
    // The Eternal token interface
    IERC20 private eternal;
    // The address of the ETRNL/AVAX pair
    address private joePair;
    // The keccak256 hash of this contract's address
    bytes32 public immutable entity;

/////–––««« Variables: Hidden Mappings »»»––––\\\\\
/**
    // The amount of ETRNL staked by any given individual user, converted to the "reserve" number space for fee distribution
    mapping (address => uint256) reserveBalances

    // The amount of ETRNL staked by any given individual user, converted to the regular number space (raw number, no fees)
    mapping (address => uint256) stakedBalances

    // The amount of a given asset provided by a user in a liquid gage of said asset
    mapping (address => mapping (address => uint256)) amountProvided

    // The amount of liquidity tokens provided for a given ETRNL/Asset pair
    mapping (address => mapping (address => uint256)) liquidityProvided
*/

/////–––««« Variables: Automatic Liquidity Provision »»»––––\\\\\

    // Determines whether the contract is tasked with providing liquidity using part of the transaction fees
    bytes32 public immutable autoLiquidityProvision;
    // Determines whether an auto-liquidity provision process is undergoing
    bool private undergoingSwap;

/////–––««« Variables: Gaging & Staking »»»––––\\\\\

    // The total number of ETRNL staked by users 
    bytes32 public immutable totalStakedBalances;
    // Used to increase or decrease everyone's accumulated fees
    bytes32 public immutable reserveStakedBalances;
    // The (percentage) fee rate applied to any gage-reward computations not using ETRNL (x 10 ** 5)
    bytes32 public immutable feeRate;

    // Allows contract to receive AVAX tokens
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

/////–––««« Constructors & Initializers »»»––––\\\\\

    constructor (address _eternalStorage, address _eternalFactory, address _eternal) {
        // Set initial Storage, Factory and Token addresses
        eternalStorage = IEternalStorage(_eternalStorage);
        eternalFactory = IEternalFactory(_eternalFactory);
        eternal = IERC20(_eternal);

        // Initialize the Trader Joe router
        IJoeRouter02 _joeRouter = IJoeRouter02(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);
        joeRouter = _joeRouter;
        IJoeFactory _joeFactory = IJoeFactory(_joeRouter.factory());
        joeFactory = _joeFactory;

        // Create pair address
        joePair = _joeFactory.createPair(address(eternal), _joeRouter.WAVAX());

        // Initialize keccak256 hashes
        entity = keccak256(abi.encodePacked(address(this)));
        autoLiquidityProvision = keccak256(abi.encodePacked("autoLiquidityProvision"));
        totalStakedBalances = keccak256(abi.encodePacked("totalStakedBalances"));
        reserveStakedBalances = keccak256(abi.encodePacked("reserveStakedBalances"));
        feeRate = keccak256(abi.encodePacked("feeRate"));
    }

    function initialize(address _fund) external onlyAdmin {
        // The largest possible number in a 256-bit integer 
        uint256 max = ~uint256(0);

        // Set initial staking balances
        uint256 totalStake = eternal.balanceOf(address(this));
        eternalStorage.setUint(entity, totalStakedBalances, totalStake);
        eternalStorage.setUint(entity, reserveStakedBalances, (max - 100 * (max % totalStake)));
        eternalStorage.setUint(entity, keccak256(abi.encodePacked("stakedBalances", address(this))), totalStake);
        eternalStorage.setUint(entity, keccak256(abi.encodePacked("reserveBalances", address(this))), max - 100 * (max % totalStake));
        eternalStorage.setBool(entity, autoLiquidityProvision, true);
        
        // Set initial feeRate
        eternalStorage.setUint(entity, feeRate, 500);

        attributeFundRights(_fund);
    }

/////–––««« Modifiers »»»––––\\\\\

    /**
     * Ensures the contract doesn't affect its AVAX balance when swapping (prevents it from getting caught in a circular liquidity event).
     */
    modifier haltsActivity() {
        undergoingSwap = true;
        _;
        undergoingSwap = false;
    }

    /**
     * Reverts if activity is halted (a liquidity swap is in progress)
     */
    modifier activityHalted() {
        require(!undergoingSwap, "A liquidity swap is in progress");
        _;
    }

/////–––««« Variable state-inspection functions »»»––––\\\\\

    /**
     * @notice View the address of the ETRNL/AVAX pair on Trader Joe.
     */
    function viewPair() external view override returns(address) {
        return joePair;
    }

    /**
     * @notice View whether a liquidity swap is currently in progress
     */
    function viewUndergoingSwap() external view override returns(bool) {
        return undergoingSwap;
    }

/////–––««« Reserve Utility functions »»»––––\\\\\

    /**
     * @notice Converts a given staked amount to the "reserve" number space
     * @param amount The specified staked amount
     * @return The reserve number space of the staked amount
     */
    function convertToReserve(uint256 amount) public view override returns(uint256) {
        uint256 currentRate = eternalStorage.getUint(entity, reserveStakedBalances) / eternalStorage.getUint(entity, totalStakedBalances);
        return amount * currentRate;
    }

    /**
     * @notice Converts a given reserve amount to the regular number space (staked)
     * @param reserveAmount The specified reserve amount
     * @return The regular number space value of the reserve amount
     */
    function convertToStaked(uint256 reserveAmount) public view override returns(uint256) {
        uint256 currentRate = eternalStorage.getUint(entity, reserveStakedBalances) / eternalStorage.getUint(entity, totalStakedBalances);
        return reserveAmount / currentRate;
    }

    /**
     * @notice Computes the equivalent of an asset to an other asset and the minimum amount of the two needed to provide liquidity
     * @param asset The first specified asset, which we want to convert 
     * @param otherAsset The other specified asset
     * @param amountAsset The amount of the first specified asset
     * @param uncertainty The minimum loss to deduct from each minimum in case of price changes
     * @return minOtherAsset The minimum amount of otherAsset needed to provide liquidity (not given if uncertainty = 0)
     * @return minAsset The minimum amount of Asset needed to provide liquidity (not given if uncertainty = 0)
     * @return amountOtherAsset The equivalent in otherAsset of the given amount of asset
     */
    function computeMinAmounts(address asset, address otherAsset, uint256 amountAsset, uint256 uncertainty) public view override returns(uint256 minOtherAsset, uint256 minAsset, uint256 amountOtherAsset) {
        // Get the reserve ratios for the Asset-otherAsset pair
        (uint256 reserveAsset, uint256 reserveOtherAsset) = _fetchPairReserves(asset, otherAsset);
        // Determine a reasonable minimum amount of asset and otherAsset based on current reserves (with a tolerance =  1 / uncertainty)
        amountOtherAsset = joeRouter.quote(amountAsset, reserveAsset, reserveOtherAsset);
        if (uncertainty != 0) {
            minAsset = joeRouter.quote(amountOtherAsset, reserveOtherAsset, reserveAsset);
            minAsset -= minAsset / uncertainty;
            minOtherAsset = amountOtherAsset - (amountOtherAsset / uncertainty);
        }
    }
    
    /**
     * @notice View the liquidity reserves of a given asset pair on Trader Joe
     * @param asset The first asset of the specified pair
     * @param otherAsset The second asset of the specified pair
     * @return reserveAsset The reserve amount of the first asset
     * @return reserveOtherAsset The reserve amount of the second asset
     */
    function _fetchPairReserves(address asset, address otherAsset) private view returns(uint256 reserveAsset, uint256 reserveOtherAsset) {
        (uint256 reserveA, uint256 reserveB,) = IJoePair(joeFactory.getPair(asset, otherAsset)).getReserves();
        (reserveAsset, reserveOtherAsset) = asset < otherAsset ? (reserveA, reserveB) : (reserveB, reserveA);
    }

    /**
     * @notice Removes liquidity provided by a liquid gage, for a given ETRNL-Asset pair
     * @param rAsset The address of the specified asset
     * @param providedAsset The amount of the asset which was provided as liquidity
     * @param receiver The address of the liquid gage's receiver
     * @return The amount of ETRNL and Asset obtained from removing liquidity
     */
    function _removeLiquidity(address rAsset, uint256 providedAsset, address receiver) private returns(uint256, uint256) {
        (uint256 minETRNL, uint256 minAsset,) = computeMinAmounts(rAsset, address(eternal), providedAsset, 100);
        uint256 liquidity = eternalStorage.getUint(entity, keccak256(abi.encodePacked("liquidity", receiver, rAsset)));
        return joeRouter.removeLiquidity(address(eternal), rAsset, liquidity, minETRNL/2, minAsset/2, address(this), block.timestamp);
    }

    /**
     * @notice Swap a given amount of tokens for ETRNL
     * @param amount The specified amount of tokens
     * @param asset The address of the asset being swapped
     * @return minAsset The minimum amount of tokens received from the swap with a 1% uncertainty
     */
    function _swapTokensForETRNL(uint256 amount, address asset) private returns(uint256 minAsset) {
        address[] memory path = new address[](2);
        path[0] = asset;
        path[1] = address(eternal);

        // Calculate the minimum amount of ETRNL to swap the asset for (with a tolerance of 1%)
        (uint256 reserveETRNL, uint256 reserveAsset) = _fetchPairReserves(address(eternal), asset);
        minAsset = _computeMinSwapAmount(amount, reserveAsset, reserveETRNL, 100);

        // Swap the asset for ETRNL
        require(IERC20(asset).approve(address(joeRouter), amount), "Approve failed");
        if (asset == joeRouter.WAVAX()) {
            joeRouter.swapExactAVAXForTokensSupportingFeeOnTransferTokens{value : amount}(minAsset, path, address(this), block.timestamp);
        } else {
            joeRouter.swapExactTokensForTokens(amount, minAsset, path, address(this), block.timestamp);
        }
    }

/////–––««« Gage-logic functions »»»––––\\\\\

    /**
     * @notice Funds a given liquidity gage with ETRNL, provides liquidity using ETRNL and the receiver's asset and transfers a bonus to the receiver
     * @param gage The address of the specified liquidity gage
     * @param receiver The address of the receiver
     * @param asset The address of the asset provided by the receiver
     * @param userAmount The amount of the asset provided by the receiver
     * @param rRisk The treasury's (distributor) risk percentage 
     * @param dRisk The receiver's bonus percentage
     * 
     * Requirements:
     *
     * - Only callable by the Eternal Platform
     */
    function fundEternalLiquidGage(address gage, address receiver, address asset, uint256 userAmount, uint256 rRisk, uint256 dRisk) external payable override {
        // Checks
        require(_msgSender() == address(eternalFactory), "msg.sender must be the platform");

        // Compute minimum amounts and the amount of ETRNL needed to provide liquidity
        uint256 providedETRNL;
        uint256 providedAsset;
        uint256 liquidity;
        (uint256 minETRNL, uint256 minAsset, uint256 amountETRNL) = computeMinAmounts(asset, address(eternal), userAmount, 100);
        
        // Add liquidity to the ETRNL/Asset pair
        require(eternal.approve(address(joeRouter), amountETRNL), "Approve failed");
        if (asset == joeRouter.WAVAX()) {
            (providedETRNL, providedAsset, liquidity) = joeRouter.addLiquidityAVAX{value: msg.value}(address(eternal), amountETRNL, minETRNL, minAsset, address(this), block.timestamp);
        } else {
            (providedETRNL, providedAsset, liquidity) = joeRouter.addLiquidity(address(eternal), asset, amountETRNL, userAmount, minETRNL, minAsset, address(this), block.timestamp);
        }
        
        // Save the true amount provided as liquidity by the receiver and the actual liquidity amount
        eternalStorage.setUint(entity, keccak256(abi.encodePacked("amountProvided", receiver, asset)), providedAsset);
        eternalStorage.setUint(entity, keccak256(abi.encodePacked("liquidity", receiver, asset)), liquidity);
        
        // Initialize the liquid gage and transfer the user's instant reward
        ILoyaltyGage(gage).initialize(asset, address(eternal), userAmount, providedETRNL, rRisk, dRisk);
        require(eternal.transfer(receiver, providedETRNL * dRisk / (10 ** 4)), "Failed to transfer bonus");
    }

    /**
     * @notice Settles a given ETRNL liquid gage
     * @param receiver The address of the receiver
     * @param id The id of the specified liquid gage
     * @param winner Whether the gage closed in favor of the receiver or not
     *
     * Requirements:
     *
     * - Only callable by an Eternal-deployed gage
     */
    function settleGage(address receiver, uint256 id, bool winner) external override activityHalted {
        // Checks
        bytes32 factory = keccak256(abi.encodePacked(address(eternalFactory)));
        address gageAddress = eternalStorage.getAddress(factory, keccak256(abi.encodePacked("gages", id)));
        require(_msgSender() == gageAddress, "msg.sender must be the gage");

        // Fetch the liquid gage data
        (address rAsset,, uint256 rRisk) = ILoyaltyGage(gageAddress).viewUserData(receiver);
        (,uint256 dAmount, uint256 dRisk) = ILoyaltyGage(gageAddress).viewUserData(address(this));
        uint256 providedAsset = eternalStorage.getUint(entity, keccak256(abi.encodePacked("amountProvided", receiver, rAsset)));

        // Remove the liquidity for this gage
        (uint256 amountETRNL, uint256 amountAsset) = _removeLiquidity(rAsset, providedAsset, receiver);

        // Compute and transfer the net gage deposit + any rewards due to the receiver
        uint256 eternalRewards = amountETRNL > dAmount ? amountETRNL - dAmount : 0;
        uint256 eternalFee = eternalStorage.getUint(entity, feeRate) * providedAsset / (10 ** 5);
        if (winner) {
            require(eternal.transfer(receiver, amountETRNL * dRisk / (10 ** 4)), "Failed to transfer ETRNL reward");
            // Compute the net liquidity rewards left to distribute to stakers
            //solhint-disable-next-line reentrancy
            eternalRewards = eternalRewards == 0 ? 0 : eternalRewards - (eternalRewards * dRisk / (10 ** 4));
        } else {
            eternalFee += amountAsset * rRisk / (10 ** 4);
            amountAsset -= amountAsset * rRisk / (10 ** 4);
            // Compute the net liquidity rewards + gage deposit left to distribute to staker
            //solhint-disable-next-line reentrancy
            eternalRewards = amountETRNL * rRisk / (10 ** 4);
        }
        if (rAsset != joeRouter.WAVAX()) {
            require(IERC20(rAsset).transfer(receiver, amountAsset - eternalFee), "Failed to transfer ERC20 reward");
        } else {
            IWAVAX(rAsset).deposit{value: amountAsset}();
            IWAVAX(rAsset).withdraw(amountAsset);
            (bool success, ) = payable(receiver).call{value: amountAsset}("");
            require(success, "Failed to transfer AVAX reward");
        }

        // Update staker's fees w.r.t the gage fee, gage rewards and liquidity rewards and buy ETRNL with the fee
        // Fees and rewards are both calculated in terms of ETRNL
        {
        uint256 totalFee = eternalRewards + _swapTokensForETRNL(eternalFee, rAsset);
        eternalStorage.setUint(entity, reserveStakedBalances, eternalStorage.getUint(entity, reserveStakedBalances) - convertToReserve(totalFee));
        }
    }

/////–––««« Staking-logic functions »»»––––\\\\\

    /**
     * @notice Stakes a given amount of ETRNL into the treasury
     * @param amount The specified amount of ETRNL being staked
     * 
     * Requirements:
     * 
     * - Staked amount must be greater than 0
     */
    function stake(uint256 amount) external override {
        require(amount > 0, "Amount must be greater than 0");

        require(eternal.transferFrom(_msgSender(), address(this), amount), "Transfer failed");
        emit Stake(_msgSender(), amount);

        // Update user/total staked and reserve balances
        bytes32 reserveBalances = keccak256(abi.encodePacked("reserveBalances", _msgSender()));
        bytes32 stakedBalances = keccak256(abi.encodePacked("stakedBalances", _msgSender()));
        uint256 reserveAmount = convertToReserve(amount);
        uint256 reserveBalance = eternalStorage.getUint(entity, reserveBalances);
        uint256 stakedBalance = eternalStorage.getUint(entity, stakedBalances);
        eternalStorage.setUint(entity, reserveBalances, reserveBalance + reserveAmount);
        eternalStorage.setUint(entity, stakedBalances, stakedBalance + amount);
        eternalStorage.setUint(entity, reserveStakedBalances, eternalStorage.getUint(entity, reserveStakedBalances) + reserveAmount);
        eternalStorage.setUint(entity, totalStakedBalances, eternalStorage.getUint(entity, totalStakedBalances) + amount);
    }

    /**
     * @notice Unstakes a user's given amount of ETRNL and transfers the user's accumulated rewards proportional to that amount (in ETRNL)
     * @param amount The specified amount of ETRNL being unstaked
     * 
     * Requirements:
     *
     * - A liquidity swap should not be in progress
     */
    function unstake(uint256 amount) external override {
        bytes32 stakedBalances = keccak256(abi.encodePacked("stakedBalances", _msgSender()));
        uint256 stakedBalance = eternalStorage.getUint(entity, stakedBalances);
        require(amount <= stakedBalance , "Amount exceeds staked balance");
     
        emit Unstake(_msgSender(), amount);
        bytes32 reserveBalances = keccak256(abi.encodePacked("reserveBalances", _msgSender()));
        uint256 reserveBalance = eternalStorage.getUint(entity, reserveBalances);
        // Reward user with percentage of fees proportional to the amount he is withdrawing
        uint256 reserveAmount = amount * reserveBalance / stakedBalance;
        // Update user/total staked and reserve balances
        eternalStorage.setUint(entity, reserveBalances, reserveBalance - reserveAmount);
        eternalStorage.setUint(entity, stakedBalances, stakedBalance - amount);
        eternalStorage.setUint(entity, reserveStakedBalances, eternalStorage.getUint(entity, reserveStakedBalances) - reserveAmount);
        eternalStorage.setUint(entity, totalStakedBalances, eternalStorage.getUint(entity, totalStakedBalances) - amount);

        require(eternal.transfer(_msgSender(), convertToStaked(reserveAmount)), "Transfer failed");
    }

/////–––««« Automatic liquidity provision functions »»»––––\\\\\

    /**
     * @notice Computes the minimum amount to swap a given asset for another asset, with a given percentage uncertainty
     * @param amountAsset The specified asset being swapped
     * @param reserveAsset The reserve of the asset being swapped
     * @param reserveOtherAsset The reserve of the asset being swapped for
     * @param uncertainty The denominator of the percentage uncertainty if it were viewed as (1  / uncertainty)
     */
    function _computeMinSwapAmount(uint256 amountAsset, uint256 reserveAsset, uint256 reserveOtherAsset, uint256 uncertainty) private view returns(uint256 minOtherAsset) {
        uint256 amountOtherAsset = joeRouter.getAmountOut(amountAsset, reserveAsset, reserveOtherAsset);
        minOtherAsset = amountOtherAsset - (amountOtherAsset / uncertainty);
    }

    /**
     * @notice Swaps a given amount of ETRNL for AVAX using Trader Joe. (Used for auto-liquidity swaps)
     * @param amount The amount of ETRNL to be swapped for AVAX
     */
    function _swapETRNLForAVAX(uint256 amount, uint256 reserveETRNL, uint256 reserveAVAX) private {
        address[] memory path = new address[](2);
        path[0] = address(eternal);
        path[1] = joeRouter.WAVAX();

        // Calculate the minimum amount of AVAX to swap the ETRNL for (with a tolerance of 1%)
        uint256 minAVAX = _computeMinSwapAmount(amount, reserveETRNL, reserveAVAX, 100);

        // Swap the ETRNL for AVAX
        require(eternal.approve(address(joeRouter), amount), "Approve failed");
        joeRouter.swapExactTokensForAVAXSupportingFeeOnTransferTokens(amount, minAVAX, path, address(this), block.timestamp);
    }

    /**
     * @notice Provides liquidity to the ETRNL/AVAX pair on Trader Joe for the EternalToken contract.
     * @param contractBalance The contract's ETRNL balance
     *
     * Requirements:
     * 
     * - There cannot already be a liquidity swap in progress
     * - Automatic liquidity provision must be enabled
     * - Caller can only be the Eternal Token contract
     */
    function provideLiquidity(uint256 contractBalance) external override activityHalted {
        require(_msgSender() == address(eternal), "Only callable by ETRNL contract");
        require(eternalStorage.getBool(entity, autoLiquidityProvision), "Auto-liquidity is disabled");

        _provideLiquidity(contractBalance);
    } 

    /**
     * @notice Converts half the contract's balance to AVAX and adds liquidity to the ETRNL/AVAX pair.
     * @param contractBalance The contract's ETRNL balance
     */
    function _provideLiquidity(uint256 contractBalance) private haltsActivity {
        // Split the contract's balance into two halves
        uint256 half = contractBalance / 2;
        uint256 amountETRNL = contractBalance - half;

        // Get the reserve ratios for the ETRNL-AVAX pair
        (uint256 reserveETRNL, uint256 reserveAVAX) = _fetchPairReserves(address(eternal), joeRouter.WAVAX());
        // Capture the initial balance to later compute the difference
        uint256 initialBalance = address(this).balance;
        // Swap half the contract's ETRNL balance to AVAX
        _swapETRNLForAVAX(half, reserveETRNL, reserveAVAX);
        // Compute the amount of AVAX received from the swap
        uint256 amountAVAX = address(this).balance - initialBalance;
        
        // Determine a reasonable minimum amount of ETRNL and AVAX based on current reserves (with a tolerance of 1%)
        uint256 minAVAX = joeRouter.quote(amountETRNL, reserveETRNL, reserveAVAX);
        minAVAX -= minAVAX / 100;
        uint256 minETRNL = joeRouter.quote(amountAVAX, reserveAVAX, reserveETRNL);
        minETRNL -= minETRNL / 100;

        // Add liquidity to the ETRNL/AVAX pair
        emit AutomaticLiquidityProvision(amountETRNL, contractBalance, amountAVAX);
        eternal.approve(address(joeRouter), amountETRNL);
        // Update the total liquidity 
        (,,uint256 liquidity) = joeRouter.addLiquidityAVAX{value: amountAVAX}(address(eternal), amountETRNL, minETRNL, minAVAX, address(this), block.timestamp);
        bytes32 totalLiquidity = keccak256(abi.encodePacked("liquidityProvided", address(this), joeRouter.WAVAX()));
        uint256 currentLiquidity = eternalStorage.getUint(entity, totalLiquidity);
        eternalStorage.setUint(entity, totalLiquidity, currentLiquidity + liquidity);
    }

/////–––««« Fund-only functions »»»––––\\\\\

    /**
     * @notice Transfers a given amount of AVAX from the contract to an address. (Fund only)
     * @param recipient The address to which the AVAX is to be sent
     * @param amount The specified amount of AVAX to transfer
     * 
     * Requirements:
     * 
     * - Only callable by the Eternal Fund
     * - A liquidity swap should not be in progress
     * - The contract's balance must have enough funds to accomodate the withdrawal
     */
    function withdrawAVAX(address recipient, uint256 amount) external override onlyFund activityHalted {
        require(amount < address(this).balance, "Insufficient balance");

        emit AVAXTransferred(amount, recipient);
        (bool success, ) = payable(recipient).call{value: amount}("");
        require(success, "Failed to transfer AVAX");
    }

    /**
     * @notice Transfers a given amount of a token from the contract to an address. (Fund only)
     * @param asset The address of the asset being withdrawn
     * @param recipient The address to which the ETRNL is to be sent
     * @param amount The specified amount of ETRNL to transfer
     *
     * Requirements:
     *
     * - Only callable by the Eternal Fund
     */
    function withdrawAsset(address asset, address recipient, uint256 amount) external override onlyFund {
        emit AssetTransferred(asset, amount, recipient);
        require(IERC20(asset).transfer(recipient, amount), "Asset withdrawal failed");
    }

    /**
     * @notice Updates the address of the Eternal Factory contract
     * @param newContract The new address for the Eternal Factory contract
     *
     * Requirements:
     *
     * - Only callable by the Eternal Fund
     */
    function setEternalFactory(address newContract) external onlyFund {
        eternalFactory = IEternalFactory(newContract);
    }

    /**
     * @notice Updates the address of the Eternal Token contract
     * @param newContract The new address for the Eternal Token contract
     *
     * Requirements:
     *
     * - Only callable by the Eternal Fund
     */
    function setEternalToken(address newContract) external onlyFund {
        eternal = IERC20(newContract);
    }
 }