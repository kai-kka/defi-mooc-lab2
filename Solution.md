# Solution and Discussion of defi-mooc-lab2

## Get the API url from Alchemy (Required)
1. Sign in an Alchemy account.
2. Create an app.
3. Copy Endpoint URL on the app's dashboard.
4. Create an ```.env``` file and store the API url as ```ALCHE_API```.

## Run with Docker 
Build Docker image:
```bash
docker build -t flash_loan_liquidation .
```
Run Docker image interactively:
```bash
docker run -it --rm flash_loan_liquidation bash
```
Compile and run the test in the docker container:
```bash
npx hardhat compile
npx hardhat test
```

## Liquidation Transaction Analysis
Here is a summary of the liquidation transaction log shown in [here](https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077#eventlog).
1. Swaps 2919549181195 ```USDC``` to 2916358033172 ```USDT``` using Curve: DAI/USDC/USDT Pool
2. Liquidates ```0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F``` using 2916378221684 ```USDT``` (balance in wallet + 2916358033172 swapped in step 1) and receive a collateral worth of 9427338222 ```WBTC```.
3. Swaps 8905424008 ```WBTC``` to 1477402720015790673349 ```WETH```.
4. Swaps 1477402720015790673349 ```WETH``` to 2919549181195 ```USDC```.

## Modification made to the skeleton code
This repo is cloned from [KaihuaQin/defi-mooc-lab2](https://github.com/KaihuaQin/defi-mooc-lab2), which was not under maintained anymore. Hence, here are a few modifications need to be made to ensure the test can be run successfully.
1. Use hardhat ```v2.25.0``` instead of ```v2.6.1``` due to the JSON-RPC schema error (missing of the totalDifficulty argument in the latest Ethereum node reponses).
2. Use ```SafeERC20``` so that the contract can transfer non-standard ERC20 tokens (USDT, etc.). See [here](https://medium.com/@JohnnyTime/why-you-should-always-use-safeerc20-94f44aa852d8).
3. Include the ```dotenv``` dependency to get the ```process.env.ALCHE_API``` variable.

## Implementation
Here is a summary of the contract's liquidation operation.
1. Gets the health factor of the target address ```0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F```. If the health factor is below 1, continue the operation.
2. Gets a ```USDT``` flash loan from the UniswapV2 USDC/USDT pool.
3. Liquidates the target address in the ```uniswapV2Call()``` callback. Then, the contract swaps the collateral (```WBTC```->```WETH```). To return the flash loan, the contract calculates the amount owed (flash loan amount + 0.3%) to the UniswapV2 USDC/USDT pool and the ```WETH``` amount needed to swap ```WETH``` to the amount owed in ```USDT```. The contract performs the swapping and repays the flash loan.
4. Withdraws the remaining ```WETH``` and transfers them to the contact's owner address.


## Profit (```ETH```)
In this case study, the profit (```ETH```) may increase/decrease based on the following factors:
1. The tokens' reserve in the swap pool. Due to the [AMM's mechanism](https://blog.uniswap.org/what-is-an-automated-market-maker) used in DeFi, the liquidators can increase their profit by swapping the tokens in the pool where the ```token_in_reserve``` < ```token_out_reserve```. In addition, when the ```token_in``` increase, the price per unit of ```token_out``` decrease. Hence, I believe this is why it is not always the most profitable when the liquidators pay the maximum debt and swap the collateral to other token in the same pool. For example, if the ```debt_to_cover``` is set to the ```USDT``` value (2916358033172) used in the [legitimate liquidation transaction](#liquidation-transaction-analysis), the contract can only receive a profit of 19.40 ```ETH```. However, when the ```debt_to_cover``` is set to 1555555555555 (a magic value generated based on manual testing), the contract can receive a profit of 40.89 ```ETH```. 
2. Swap fees. Liquidators must account the swap fees (0.3% per swap for UniswapV2) when estimating potential profit. These fees accumulate when the liquidators use multiple swap routes to convert the received collateral into the asset required to repay the flash loan. In this case study, the liquidation yields ```WBTC```, but the flash loan is in ```USDT```. Because the ```USDT``` reserve in the UniswapV2 WBTC/USDT pool is low, the contract cannot swap ```WBTC```->```USDT``` directly. Instead, it swaps ```WBTC```->```WETH``` and ```WETH```->```USDT``` to repay the flash loan. Multi-hop swapping reduces the net liquidation profit because each additional hop increases the total amount of assets required to repay the flash loan.
2. Gas price. Since this testing script set the gas price to 0, this factor was not considered when maximising the liquidation profit.