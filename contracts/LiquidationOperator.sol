//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// // https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// // https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
// interface IERC20 {
//     // Returns the account balance of another account with address _owner.
//     function balanceOf(address owner) external view returns (uint256);

//     /**
//      * Allows _spender to withdraw from your account multiple times, up to the _value amount.
//      * If this function is called again it overwrites the current allowance with _value.
//      * Lets msg.sender set their allowance for a spender.
//      **/
//     function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

//     /**
//      * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
//      * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
//      * Lets msg.sender send pool tokens to an address.
//      **/
//     function transfer(address to, uint256 value) external returns (bool);
// }

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    using SafeERC20 for IERC20;

    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    // Owner of this contract
    address public owner;

    // The lending pool the liquidator repay and get the collateral (Aave Lending Pool V2)
    ILendingPool public i_lending_pool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    // The Uniswap factory
    IUniswapV2Factory public uniswap_factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);

    // Tokens used in this liquidation
    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Target user address and variable
    address target_user = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    uint256 debt_to_cover = 2916378221684;
    // uint256 debt_to_cover = 2016378221684;
    uint256 profit_weth = 0;

    uint256 expected_health_factor = 10 ** health_factor_decimals;
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        owner = msg.sender;
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    receive() external payable {}

    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***
        require(msg.sender == owner, "Only owner can trigger");

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        // check whether the user's health factor is below 1
        (,,,,,uint256 health_factor) = i_lending_pool.getUserAccountData(target_user);
        require(health_factor < expected_health_factor, "The target address is not liquidatable");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***
        address usdc_usdt = uniswap_factory.getPair(USDC, USDT);
        IUniswapV2Pair usdc_usdt_pair = IUniswapV2Pair(usdc_usdt);
        address token0 = usdc_usdt_pair.token0();

        // call the flash loan here with data size != 0
        if(token0 == USDC) {
            usdc_usdt_pair.swap(0, debt_to_cover, address(this), bytes("flash loan"));
        } else {
            usdc_usdt_pair.swap(debt_to_cover, 0, address(this), bytes("flash loan"));
        }

        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***
        // The remaining WBTC is the profit
        uint256 weth_bal = IERC20(WETH).balanceOf(address(this));

        // withdraw the WETH to ETH
        IWETH(WETH).withdraw(weth_bal);

        // Ensure the contract has enough ETH as required
        require(address(this).balance >= weth_bal, "Not enough ETH");

        // Send ETH to the caller/owner
        (bool success, ) = msg.sender.call{value: weth_bal}("");
        require(success, "ETH transfer failed");

        // END TODO
    }

    // swap WBTC->WETH->USDT
    function swap_weth_usdt (uint256 amount_owed, uint256 wbtc_bal) internal {
        // get the pair to do the swap
        // swap WBTC->WETH
        address wbtc_weth = uniswap_factory.getPair(WBTC, WETH);
        IUniswapV2Pair wbtc_weth_pair = IUniswapV2Pair(wbtc_weth);
        uint256 wbtc_weth_pair_wbtc_reserve = 0;
        uint256 wbtc_weth_pair_weth_reserve = 0;

        if(wbtc_weth_pair.token0() == WBTC) {
            (wbtc_weth_pair_wbtc_reserve, wbtc_weth_pair_weth_reserve,) = wbtc_weth_pair.getReserves();
        } else {
            (wbtc_weth_pair_weth_reserve, wbtc_weth_pair_wbtc_reserve,) = wbtc_weth_pair.getReserves();
        }

        // calculate how much WETH we get back
        uint256 weth_to_recv = getAmountOut(wbtc_bal, wbtc_weth_pair_wbtc_reserve, wbtc_weth_pair_weth_reserve);

        // transfer WBTC to the swap pool
        IERC20(WBTC).safeTransfer(wbtc_weth, wbtc_bal);

        // swap all WBTC to WETH
        if(wbtc_weth_pair.token0() == WBTC) {
            wbtc_weth_pair.swap(0, weth_to_recv, address(this), bytes(""));
        } else {
            wbtc_weth_pair.swap(weth_to_recv, 0, address(this), bytes(""));
        }

        console.log();
        console.log("WETH reserve: ", wbtc_weth_pair_weth_reserve/10**18);
        console.log("WBTC reserve: ", wbtc_weth_pair_wbtc_reserve/10**8);
        console.log("WETH receive: ", weth_to_recv/10**18);
        console.log();

        // start swapping the WETH to USDT (amount_owed)
        address weth_usdt = uniswap_factory.getPair(WETH, USDT);
        IUniswapV2Pair weth_usdt_pair = IUniswapV2Pair(weth_usdt);
        uint256 weth_usdt_pair_weth_reserve = 0;
        uint256 weth_usdt_pair_usdt_reserve = 0;
        
        // calculate how much WETH we need to swap to the USDT amount_owed 
        if(weth_usdt_pair.token0() == WETH) {
            (weth_usdt_pair_weth_reserve, weth_usdt_pair_usdt_reserve,) = weth_usdt_pair.getReserves();
        } else {
            (weth_usdt_pair_usdt_reserve, weth_usdt_pair_weth_reserve,) = weth_usdt_pair.getReserves();
        }

        // calculate weth to swap
        uint256 weth_to_swap = getAmountIn(amount_owed, weth_usdt_pair_weth_reserve, weth_usdt_pair_usdt_reserve);

        // transfer WETH to the swap pool
        IERC20(WETH).safeTransfer(weth_usdt, weth_to_swap);

        // swap WETH->USDT
        if(weth_usdt_pair.token0() == WETH) {
            weth_usdt_pair.swap(0, amount_owed, address(this), bytes(""));
        } else {
           weth_usdt_pair.swap(amount_owed, 0, address(this), bytes(""));
        }

        console.log();
        console.log("WETH reserve: ", weth_usdt_pair_weth_reserve/(10**18));
        console.log("USDT reserve: ", weth_usdt_pair_usdt_reserve/(10**8));
        console.log();
    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        require(sender == address(this), "Unauthorized flash loan sender");

        // 2.1 liquidate the target user
        //    *** Your code here ***
        // approve the lending pool to get token from this address
        IERC20(USDT).safeApprove(address(i_lending_pool), debt_to_cover);

        // call liquidation function
        i_lending_pool.liquidationCall(
            WBTC,
            USDT,
            target_user,
            debt_to_cover,
            false
        );

        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        // calculate the amount owed (flash loan amount + 0.3%)
        uint256 amount_owed = debt_to_cover + (debt_to_cover * 3 / 997 + 1);
        console.log("Amount (USDT) Owed: ", amount_owed/10**8);

        // get how much WBTC collateral we claimed
        uint256 wbtc_bal = IERC20(WBTC).balanceOf(address(this));
        console.log("Collateral (WBTC) claimed: ", wbtc_bal/10**8);
        require(wbtc_bal > 0, "The balance of WBTC is below 0.");
        swap_weth_usdt(amount_owed, wbtc_bal);

        // 2.3 repay
        //    *** Your code here ***
        // repay the flash loan
        IERC20(USDT).safeTransfer(msg.sender, amount_owed);
        
        // END TODO
    }
}
