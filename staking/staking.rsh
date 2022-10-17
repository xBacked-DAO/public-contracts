'reach 0.1';

import {
  ScaleInfo,
  NETWORK_TOKEN_DECIMALS,
  checkDistinctASAs,
  checkASADecimals,
  calculateDecimalScaleFactor,
  validateRewardRatios,
  normalizeAndSelectTotalRewards,
  rewardDifferences,
  splitAndScaleRewards
} from 'distribution_utils.rsh';

import {
  getTime,
  validateDeprecateTimeout,
  checkDeprecateTimeout,
  validateDeprecateAt,
  checkDeprecateAt,
  validateRewardRate,
  checkRewardRate,
  validateRewardMethod,
  checkRewardMethod,
  checkDeposit,
  checkWithdrawal,
  checkRewardWithdrawal,
  calculateRewardRate,
  currentRewardPerToken,
  getTimeInDeprecatedState,
  updateRewards
} from 'reward_utils.rsh';

// A staking contract to be used for liquidity mining, distributing the
// provided reward asset proportionately amongst stakers.
// This contract only supports one reward pool.

// Contract static compilation variables.
// 0 is ALGO, 1 is the staked asset, the rest are proposed by the deployer.
// A value of 0 would mean that the contract would ONLY support ALGO and the
// staking asset as reward assets, for every extra asset we need to increment
// this value.
export const NUM_EXTRA_REWARD_ASSETS = 2;

// Do not change this line.
export const NUM_SUPPORTED_REWARD_ASSETS = 2 + NUM_EXTRA_REWARD_ASSETS;

const InitializationParameters = Struct([
  ['stakingASAInfo', Tuple(Token, UInt)],
  ['rewardASAInfo', Array(Tuple(Token, UInt), NUM_EXTRA_REWARD_ASSETS)],
  ['initialDeprecateTimeout', UInt],
  ['initialDeprecateAt', UInt],
  ['initialRewardRatios', Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)],
  ['initialRewardRate', UInt],
  ['initialRewards', Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)]
]);

const AdminConfigurationParameters = Struct([
  ['adminAddress', Address],
  ['deprecateTimeout', UInt],
  ['deprecateAt', UInt],
  ['rewardRatios', Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)],
  ['rewardRate', UInt]
]);

const validateAdminConfigurationParameters = ({
  deprecateTimeout,
  deprecateAt,
  rewardRate,
  rewardRatios
}) =>
  validateDeprecateTimeout(deprecateTimeout) &&
  validateDeprecateAt(deprecateAt, 0) &&
  validateRewardRatios(rewardRatios) &&
  validateRewardRate(rewardRate) &&
  validateRewardMethod(rewardRate, deprecateAt);

const checkRewardRatios = (rewardRatios) =>
  check(
    validateRewardRatios(rewardRatios),
    'The sum of all reward ratios must equal 100.'
  );

const checkAdminConfigurationParameters = (
  { deprecateTimeout, deprecateAt, rewardRate, rewardRatios },
  currentBlock
) => {
  checkDeprecateTimeout(deprecateTimeout);
  checkDeprecateAt(deprecateAt, currentBlock);
  checkRewardRate(rewardRate);
  checkRewardMethod(rewardRate, deprecateAt);
  checkRewardRatios(rewardRatios);
};

// All functions used to configure the contract upon deployment.
const AdminInteract = {
  ...hasConsoleLogger,
  setInitializationParameters: Fun([], InitializationParameters),
  isInitialized: Fun([Contract], Null)
};

// User stores the amount of staking asset they have staked,
// and the amount of rewardDebt they have accrued.
const UserState = Struct([
  // Amount of staking asset deposited.
  ['amountDeposited', UInt],
  // Used to ensure the user is only paid from the new rewards generated since
  // last interaction.
  ['rewardPerTokenPaid', UInt],
  // Rewards earned since last interaction, calculated by the earn function.
  ['rewards', UInt]
]);

const EMPTY_USER = UserState.fromObject({
  amountDeposited: 0,
  rewardPerTokenPaid: 0,
  rewards: 0
});

// Cold state of the contract, immutable after contract initialization.
const ColdState = Struct([
  ['stakingASA', Token],
  ['stakingASADecimals', UInt],
  ['rewardASAs', Array(Token, NUM_EXTRA_REWARD_ASSETS)],
  ['rewardASADecimals', Array(UInt, NUM_EXTRA_REWARD_ASSETS)],
  ['assetScaleInfos', Array(ScaleInfo, NUM_SUPPORTED_REWARD_ASSETS)]
]);

// Hot state of the contract, mutable throughout contract lifetime.
const HotState = Struct([
  // Address of current admin.
  ['adminAddress', Address],
  // How many blocks will the contract remain in the deprecated state before
  // closing.
  ['deprecateTimeout', UInt],
  // Block when the contract will be considered deprecated.
  ['deprecateAt', UInt],
  // Proportion of rewards to be distributed per reward point position,
  // always equal to 100%.
  ['rewardRatios', Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)],
  // Rate of reward asset emission.
  ['rewardRate', UInt],
  // Remaining rewards.
  ['remainingRewards', Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)],
  // Normalized representation of total rewards claimable in the contract.
  ['totalRewards', UInt],
  // Total amount of staking asset deposited.
  ['totalDeposit', UInt],
  // Last time the rewardPerToken was calculated.
  ['lastRewardBlock', UInt],
  // Last calculated reward amount per token.
  ['rewardPerToken', UInt]
]);

export const main = Reach.App(() => {
  setOptions({
    connectors: [ALGO],
    untrustworthyMaps: true
    // verifyArithmetic: true
  });

  const Admin = Participant('Admin', {
    ...AdminInteract
  });

  const AdminAPI = API('AdminAPI', {
    updateAdminParameters: Fun([AdminConfigurationParameters], Bool),
    depositRewards: Fun([Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)], Bool)
  });

  const StakingUserAPI = API('StakingUserAPI', {
    // Deposit staking asset.
    deposit: Fun([UInt], Tuple(UserState, UInt)),
    // Withdraw staking asset.
    withdraw: Fun([UInt], Tuple(UserState, UInt)),
    // Cache rewards.
    cacheRewards: Fun([], Tuple(UserState, UInt)),
    // Withdraw rewards.
    withdrawRewards: Fun(
      [UInt],
      Tuple(UserState, UInt, Array(UInt, NUM_SUPPORTED_REWARD_ASSETS))
    )
  });

  const AnyAPI = API('AnyAPI', {
    // Update the last consensus, workaround while we do not have access to
    // current network time.
    updateLastConsensus: Fun([], Bool),
    // Terminate the contract.
    halt: Fun([], Null)
  });

  // Create the Announcer and define the possible events.
  const [
    isTxnType,
    USER_DEPOSIT,
    USER_WITHDRAWAL,
    USER_REWARD_CACHE,
    USER_REWARD_WITHDRAWAL
  ] = makeEnum(4);

  const Announcer = Events('Announcer', {
    // Address of the signer, and the new admin configuration parameters.
    updateAdminParameters: [Address, AdminConfigurationParameters],
    // Address of the signer and the new reward rate.
    depositRewards: [Address, Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)],
    // Address of the signer, the type of interaction and the updated staking
    // state.
    stakeTransaction: [Address, UInt, UserState],
    // Address of the signer.
    updateLastConsensus: [Address]
  });

  const State = View('State', {
    // Get the current contract state.
    readColdState: ColdState,
    readHotState: HotState,
    // Get a user's local state.
    readUser: Fun([Address], UserState),
    // Get a user's pending rewards.
    readPendingRewards: Fun(
      [Address],
      Array(UInt, NUM_SUPPORTED_REWARD_ASSETS)
    ),
    // Get user's max claimable reward amount.
    readMaxTotalClaim: Fun([Address], UInt)
  });

  init();

  Admin.only(() => {
    const initialAdminAddress = this;

    const {
      stakingASAInfo,
      rewardASAInfo,
      initialDeprecateTimeout,
      initialDeprecateAt,
      initialRewardRatios,
      initialRewardRate,
      initialRewards
    } = declassify(interact.setInitializationParameters());

    const [stakingASA, stakingASADecimals] = stakingASAInfo;
    const rewardASAs = rewardASAInfo.map((rewardPair) => rewardPair[0]);
    const rewardASADecimals = rewardASAInfo.map((rewardPair) => rewardPair[1]);

    checkDistinctASAs(array(Token, [stakingASA, ...rewardASAs]));
    checkASADecimals(array(UInt, [stakingASADecimals, ...rewardASADecimals]));

    const rewardASA1 = rewardASAs[0];
    const rewardASA2 = rewardASAs[1];
    
    const supportedAssetDecimals = array(UInt, [
      NETWORK_TOKEN_DECIMALS,
      stakingASADecimals,
      ...rewardASADecimals
    ]);

    const assetScaleInfos = supportedAssetDecimals.map((assetDecimals) =>
      calculateDecimalScaleFactor(assetDecimals, NETWORK_TOKEN_DECIMALS)
    );

    const initialTotalRewards = normalizeAndSelectTotalRewards(
      initialRewards,
      assetScaleInfos,
      initialRewardRatios
    );

    // Calculate the reward rate if it is specified to be dynamic.
    const initialCalculatedRewardRate = calculateRewardRate(
      initialRewardRate,
      initialTotalRewards,
      0,
      initialDeprecateAt
    );

    const initialAdminParameters = AdminConfigurationParameters.fromObject({
      adminAddress: this,
      deprecateTimeout: initialDeprecateTimeout,
      deprecateAt: initialDeprecateAt,
      rewardRatios: initialRewardRatios,
      rewardRate: initialCalculatedRewardRate
    });
    checkAdminConfigurationParameters(initialAdminParameters, 0);
  });

  // Initial configuration variables of the contract.
  Admin.publish(
    stakingASA,
    stakingASADecimals,
    rewardASAs,
    rewardASADecimals,
    rewardASA1,
    rewardASA2,
    supportedAssetDecimals,
    assetScaleInfos,
    initialAdminParameters,
    initialTotalRewards
  );

  checkDistinctASAs(array(Token, [stakingASA, ...rewardASAs]));
  checkASADecimals(array(UInt, [stakingASADecimals, ...rewardASADecimals]));
  checkAdminConfigurationParameters(initialAdminParameters, 0);

  // A function we use in an attempt to reduce the diff between different
  // versions of this contract.
  const createPaymentExpression = (amountToWithdraw) => {
    assert(
      amountToWithdraw.length <= NUM_SUPPORTED_REWARD_ASSETS,
      'Too many reward amounts provided, maximum elements are the amount of reward assets supported.'
    );
    const paddedRewardAmounts = array(UInt, amountToWithdraw).concat(
      Array.replicate(NUM_SUPPORTED_REWARD_ASSETS - amountToWithdraw.length, 0)
    );
    assert(
      paddedRewardAmounts.length == NUM_SUPPORTED_REWARD_ASSETS,
      'amountToWithdraw must be an array of UInt equal in length to the number of supported reward ASAs.'
    );
    const amountToWithdrawWithoutNetwork = paddedRewardAmounts.slice(
      2,
      NUM_EXTRA_REWARD_ASSETS
    );
    return [
      paddedRewardAmounts[0],
      [paddedRewardAmounts[1], stakingASA],
      [amountToWithdrawWithoutNetwork[0], rewardASA1],
      [amountToWithdrawWithoutNetwork[1], rewardASA2]
    ];
  };

  const getStakingBalance = () => balance(stakingASA);

  const indexInAssetRange = (index) =>
    assert(
      index < NUM_SUPPORTED_REWARD_ASSETS,
      'Provided index must be within range of supported reward assets.'
    );

  const getAssetBalance = (assetIndex) => {
    indexInAssetRange(assetIndex);
    if (assetIndex == 0) {
      // ALGO.
      return balance();
    } else if (assetIndex == 1) {
      // Staking asset.
      return getStakingBalance();
    } else if (assetIndex == 2) {
      // Dynamic reward assets.
      return balance(rewardASA1);
    } else {
      // Dynamic reward assets.
      return balance(rewardASA2);
    }
  };

  const getUntrackedAssets = (assetIndex) => {
    indexInAssetRange(assetIndex);
    if (assetIndex == 0) {
      // ALGO.
      const _ = getUntrackedFunds();
    } else if (assetIndex == 1) {
      // Staking asset.
      const _ = getUntrackedFunds(stakingASA);
    } else if (assetIndex == 2) {
      // Dynamic reward assets.
      const _ = getUntrackedFunds(rewardASA1);
    } else if (assetIndex == 3) {
      // Dynamic reward assets.
      const _ = getUntrackedFunds(rewardASA2);
    }
  };

  // Static functions for withdrawing the assets from the contract.
  const withdrawStakingAsset = (to, amt) => transfer(amt, stakingASA).to(to);

  const checkAssetWithdrawal = (rewardsToWithdraw, remainingRewards) => {
    check(
      rewardsToWithdraw
        .withIndex()
        .all(
          ([toWithdraw, index]) =>
            remainingRewards[index] - toWithdraw <= getAssetBalance(index)
        ),
      'Contract cannot afford this claim.'
    );
  };

  // Withdraw provided amounts of the supported assets.
  const withdrawAssets = (addr, amountToWithdraw) =>
    transfer([
      amountToWithdraw[0],
      [amountToWithdraw[1], stakingASA],
      [amountToWithdraw[2], rewardASA1],
      [amountToWithdraw[3], rewardASA2]
    ]).to(addr);

  commit();

  // Transfer initial rewards into the contract.
  Admin.publish(initialRewards).pay(
    createPaymentExpression([...initialRewards])
  );

  // The user local storage.
  const contractUsers = new Map(UserState);

  // Shorthand function to get a user's state.
  const getUser = (addr) => fromSome(contractUsers[addr], EMPTY_USER);

  // Define the function to return a users state.
  State.readUser.set((addr) => getUser(addr));

  // Set the cold state once.
  State.readColdState.set(
    ColdState.fromObject({
      stakingASA: stakingASA,
      stakingASADecimals: stakingASADecimals,
      rewardASAs: rewardASAs,
      rewardASADecimals: rewardASADecimals,
      assetScaleInfos: assetScaleInfos
    })
  );

  const isDeprecated = (deprecateAt) =>
    deprecateAt != 0 && getTime() >= deprecateAt;

  const hasTimeoutElapsed = (deprecateTimeout, deprecateAt) =>
    getTime() > deprecateAt + deprecateTimeout;

  // Notify deployer that the contract has been deployed.
  Admin.interact.isInitialized(getContract());

  const [
    adminParameters,
    // Tracked reward balance.
    remainingRewards,
    totalRewards,
    // Last time a reward was distributed.
    lastRewardBlock,
    // Total amount of asset staked.
    totalDeposit,
    // Reward per token stored.
    rewardPerToken
  ] = parallelReduce([
    initialAdminParameters,
    initialRewards,
    initialTotalRewards,
    getTime(),
    0,
    0
  ])
    .paySpec([stakingASA, rewardASA1, rewardASA2])
    // Total balance of all reward only assets (everything other than the
    // staking asset) should always match the call to balance() for that
    // ASA. The staking asset will always be the rewards + totalDeposit.
    .invariant(
      remainingRewards
        .withIndex()
        .all(([remaining, index]) =>
          index !== 1
            ? remaining === getAssetBalance(index)
            : remaining + totalDeposit === getAssetBalance(index)
        )
    )
    // Ensure that the configuration parameters are always valid.
    .invariant(validateAdminConfigurationParameters(adminParameters))
    // The lastRewardBlock is always less than or equal to the deprecateAt
    // block when deprecateAt is set.
    .invariant(
      adminParameters.deprecateAt === 0 ||
        lastRewardBlock <= adminParameters.deprecateAt
    )
    .while(
      !(
        isDeprecated(adminParameters.deprecateAt) &&
        (hasTimeoutElapsed(
          adminParameters.deprecateTimeout,
          adminParameters.deprecateAt
        ) ||
          totalDeposit === 0)
      )
    )
    .define(() => {
      const isAdmin = (address) =>
        check(
          address == adminParameters.adminAddress,
          'You are not the admin.'
        );
      const isNotDeprecated = () =>
        check(
          !isDeprecated(adminParameters.deprecateAt),
          'This contract is deprecated.'
        );

      State.readHotState.set(
        HotState.fromObject({
          ...AdminConfigurationParameters.toObject(adminParameters),
          remainingRewards,
          totalRewards,
          totalDeposit,
          lastRewardBlock,
          rewardPerToken
        })
      );

      // Convenience views for the frontend.
      State.readPendingRewards.set((addr) =>
        splitAndScaleRewards(
          getUser(addr).rewards,
          adminParameters.rewardRatios,
          assetScaleInfos
        )
      );

      State.readMaxTotalClaim.set((addr) => {
        // Max rewards.
        const pendingRewards = getUser(addr).rewards;

        // Real scaled rewards.
        const totalScaledRewards = splitAndScaleRewards(
          pendingRewards,
          adminParameters.rewardRatios,
          assetScaleInfos
        );

        // Percentages realizable.
        const rewardPercentageDifferences = rewardDifferences(
          totalScaledRewards,
          remainingRewards
        );

        // Smallest percentage realizable.
        const smallestPercentage = rewardPercentageDifferences.reduce(
          100,
          (smallestFound, percentage) =>
            percentage < smallestFound ? percentage : smallestFound
        );

        // Largest amount of pending rewards claimable.
        return muldiv(pendingRewards, 100, smallestPercentage);
      });
    })
    .api_(AdminAPI.updateAdminParameters, (newAdminParameters) => {
      isAdmin(this);
      const currentBlock = getTime();
      checkAdminConfigurationParameters(newAdminParameters, currentBlock);

      return [
        createPaymentExpression([]),
        (apiReturn) => {
          const { rewardBlock, newRewardPerToken } = currentRewardPerToken(
            currentBlock,
            adminParameters.deprecateAt,
            getTimeInDeprecatedState(
              currentBlock,
              isDeprecated(adminParameters.deprecateAt),
              isDeprecated(newAdminParameters.deprecateAt),
              adminParameters.deprecateAt
            ),
            adminParameters.rewardRate,
            lastRewardBlock,
            rewardPerToken,
            totalDeposit
          );

          // Determine the current reward rate based on the contract configuration.
          const currentRewardRate = calculateRewardRate(
            newAdminParameters.rewardRate,
            totalRewards,
            currentBlock,
            newAdminParameters.deprecateAt
          );

          const finalAdminParameters = AdminConfigurationParameters.fromObject({
            ...AdminConfigurationParameters.toObject(newAdminParameters),
            rewardRate: currentRewardRate
          });

          Announcer.updateAdminParameters(this, finalAdminParameters);
          apiReturn(true);
          return [
            finalAdminParameters,
            remainingRewards,
            totalRewards,
            rewardBlock,
            totalDeposit,
            newRewardPerToken
          ];
        }
      ];
    })
    .api_(AdminAPI.depositRewards, (rewardsToDeposit) => {
      isNotDeprecated();
      isAdmin(this);

      return [
        createPaymentExpression([...rewardsToDeposit]),
        (apiReturn) => {
          Announcer.depositRewards(this, rewardsToDeposit);
          apiReturn(true);

          const newRemainingRewards = remainingRewards.mapWithIndex(
            (oldTotal, index) => oldTotal + rewardsToDeposit[index]
          );
          const newTotalRewards = normalizeAndSelectTotalRewards(
            newRemainingRewards,
            assetScaleInfos,
            adminParameters.rewardRatios
          );
          return [
            adminParameters,
            newRemainingRewards,
            newTotalRewards,
            lastRewardBlock,
            totalDeposit,
            rewardPerToken
          ];
        }
      ];
    })
    .api_(StakingUserAPI.deposit, (amountToDeposit) => {
      isNotDeprecated();
      checkDeposit(amountToDeposit);

      return [
        createPaymentExpression([0, amountToDeposit]),
        (apiReturn) => {
          const userData = getUser(this);
          const currentBlock = getTime();

          const { rewardBlock, newRewardPerToken, newUserRewards } =
            updateRewards(
              currentBlock,
              adminParameters.deprecateAt,
              0,
              adminParameters.rewardRate,
              lastRewardBlock,
              rewardPerToken,
              totalDeposit,
              userData.amountDeposited,
              userData.rewards,
              userData.rewardPerTokenPaid
            );

          const newUserData = UserState.fromObject({
            amountDeposited: userData.amountDeposited + amountToDeposit,
            rewards: newUserRewards,
            rewardPerTokenPaid: newRewardPerToken
          });
          contractUsers[this] = newUserData;

          Announcer.stakeTransaction(this, USER_DEPOSIT, newUserData);
          apiReturn([newUserData, rewardBlock - lastRewardBlock]);
          return [
            adminParameters,
            remainingRewards,
            totalRewards,
            rewardBlock,
            totalDeposit + amountToDeposit,
            newRewardPerToken
          ];
        }
      ];
    })
    .api_(StakingUserAPI.withdraw, (amountToWithdraw) => {
      const userData = getUser(this);
      checkWithdrawal(
        amountToWithdraw,
        userData.amountDeposited,
        totalDeposit,
        getStakingBalance()
      );

      return [
        createPaymentExpression([]),
        (apiReturn) => {
          const currentBlock = getTime();

          const { rewardBlock, newRewardPerToken, newUserRewards } =
            updateRewards(
              currentBlock,
              adminParameters.deprecateAt,
              0,
              adminParameters.rewardRate,
              lastRewardBlock,
              rewardPerToken,
              totalDeposit,
              userData.amountDeposited,
              userData.rewards,
              userData.rewardPerTokenPaid
            );

          const newUserData = UserState.fromObject({
            amountDeposited: userData.amountDeposited - amountToWithdraw,
            rewards: newUserRewards,
            rewardPerTokenPaid: newRewardPerToken
          });
          contractUsers[this] = newUserData;

          withdrawStakingAsset(this, amountToWithdraw);

          Announcer.stakeTransaction(this, USER_WITHDRAWAL, newUserData);
          apiReturn([newUserData, rewardBlock - lastRewardBlock]);
          return [
            adminParameters,
            remainingRewards,
            totalRewards,
            rewardBlock,
            totalDeposit - amountToWithdraw,
            newRewardPerToken
          ];
        }
      ];
    })
    .api_(StakingUserAPI.cacheRewards, () => {
      const userData = getUser(this);
      const currentBlock = getTime();

      const { rewardBlock, newRewardPerToken, newUserRewards } = updateRewards(
        currentBlock,
        adminParameters.deprecateAt,
        0,
        adminParameters.rewardRate,
        lastRewardBlock,
        rewardPerToken,
        totalDeposit,
        userData.amountDeposited,
        userData.rewards,
        userData.rewardPerTokenPaid
      );

      return [
        createPaymentExpression([]),
        (apiReturn) => {
          const newUserData = UserState.fromObject({
            amountDeposited: userData.amountDeposited,
            rewards: newUserRewards,
            rewardPerTokenPaid: newRewardPerToken
          });
          contractUsers[this] = newUserData;

          Announcer.stakeTransaction(this, USER_REWARD_CACHE, newUserData);
          apiReturn([newUserData, rewardBlock - lastRewardBlock]);
          return [
            adminParameters,
            remainingRewards,
            totalRewards,
            rewardBlock,
            totalDeposit,
            newRewardPerToken
          ];
        }
      ];
    })
    .api_(StakingUserAPI.withdrawRewards, (rewardsToWithdraw) => {
      // This endpoint used to cache rewards as the others do, but was
      // resulting in unacceptable verification timeout.
      // NOTE: re-implement this if possible.
      const userData = getUser(this);

      checkRewardWithdrawal(rewardsToWithdraw, userData.rewards, totalRewards);

      const rewardSpread = splitAndScaleRewards(
        rewardsToWithdraw,
        adminParameters.rewardRatios,
        assetScaleInfos
      );

      checkAssetWithdrawal(rewardSpread, remainingRewards);

      return [
        createPaymentExpression([]),
        (apiReturn) => {
          withdrawAssets(this, rewardSpread);

          const newUserData = UserState.fromObject({
            amountDeposited: userData.amountDeposited,
            rewards: userData.rewards - rewardsToWithdraw,
            rewardPerTokenPaid: userData.rewardPerTokenPaid
          });
          contractUsers[this] = newUserData;

          const newRemainingRewards = remainingRewards.mapWithIndex(
            (oldTotal, index) => oldTotal - rewardSpread[index]
          );
          const newTotalRewards = totalRewards - rewardsToWithdraw;

          Announcer.stakeTransaction(this, USER_REWARD_WITHDRAWAL, newUserData);
          apiReturn([newUserData, lastRewardBlock, remainingRewards]);
          return [
            adminParameters,
            newRemainingRewards,
            newTotalRewards,
            lastRewardBlock,
            totalDeposit,
            rewardPerToken
          ];
        }
      ];
    })
    .api_(AnyAPI.updateLastConsensus, () => {
      return [
        createPaymentExpression([]),
        (apiReturn) => {
          Announcer.updateLastConsensus(this);
          apiReturn(true);
          return [
            adminParameters,
            remainingRewards,
            totalRewards,
            lastRewardBlock,
            totalDeposit,
            rewardPerToken
          ];
        }
      ];
    });

  commit();
  const [[], haltK] = call(AnyAPI.halt);
  haltK(null);

  // Become aware of all extra assets within the account, and transfer them to
  // the current admin address. We cannot rely on default behavior in the case
  // that the Admin has been changed.
  const _ = Array.iota(NUM_SUPPORTED_REWARD_ASSETS).map((index) =>
    getUntrackedAssets(index)
  );
  const toWithdraw = Array.iota(NUM_SUPPORTED_REWARD_ASSETS).map((index) =>
    getAssetBalance(index)
  );
  const _ = withdrawAssets(adminParameters.adminAddress, toWithdraw);
  commit();
  exit();
});
