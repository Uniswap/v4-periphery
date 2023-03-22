  describe('#place', async () => {
    it('#ZeroLiquidity', async () => {
      const tickLower = 0
      const zeroForOne = true
      const liquidity = 0
      await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity)).to.be.revertedWith('ZeroLiquidity()')
    })

    describe('zeroForOne = true', async () => {
      const zeroForOne = true
      const liquidity = 1000000

      it('works from the right boundary of the current range', async () => {
        const tickLower = key.tickSpacing
        await limitOrderHook.place(key, tickLower, zeroForOne, liquidity)
        expect(await limitOrderHook.getEpoch(key, tickLower, zeroForOne)).to.eq(1)
        expect(
          await manager['getLiquidity(bytes32,address,int24,int24)'](
            getPoolId(key),
            limitOrderHook.address,
            tickLower,
            tickLower + key.tickSpacing
          )
        ).to.eq(liquidity)
      })

      it('works from the left boundary of the current range', async () => {
        const tickLower = 0
        await limitOrderHook.place(key, tickLower, zeroForOne, liquidity)
        expect(await limitOrderHook.getEpoch(key, tickLower, zeroForOne)).to.eq(1)
        expect(
          await manager['getLiquidity(bytes32,address,int24,int24)'](
            getPoolId(key),
            limitOrderHook.address,
            tickLower,
            tickLower + key.tickSpacing
          )
        ).to.eq(liquidity)
      })

      it('#CrossedRange', async () => {
        const tickLower = -key.tickSpacing
        await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity)).to.be.revertedWith('CrossedRange()')
      })

      it('#InRange', async () => {
        await swapTest.swap(
          key,
          {
            zeroForOne: false,
            amountSpecified: 1, // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
            sqrtPriceLimitX96: encodeSqrtPriceX96(1, 1).add(1),
          },
          {
            withdrawTokens: true,
            settleUsingTransfer: true,
          }
        )

        const tickLower = 0
        await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity)).to.be.revertedWith('InRange()')
      })
    })

    describe('zeroForOne = false', async () => {
      const zeroForOne = false
      const liquidity = 1000000

      it('works up until the left boundary of the current range', async () => {
        const tickLower = -key.tickSpacing
        await limitOrderHook.place(key, tickLower, zeroForOne, liquidity)
        expect(await limitOrderHook.getEpoch(key, tickLower, zeroForOne)).to.eq(1)
        expect(
          await manager['getLiquidity(bytes32,address,int24,int24)'](
            getPoolId(key),
            limitOrderHook.address,
            tickLower,
            tickLower + key.tickSpacing
          )
        ).to.eq(liquidity)
      })

      it('#CrossedRange', async () => {
        const tickLower = 0
        await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity)).to.be.revertedWith('CrossedRange()')
      })

      it('#InRange', async () => {
        await swapTest.swap(
          key,
          {
            zeroForOne: true,
            amountSpecified: 1, // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
            sqrtPriceLimitX96: encodeSqrtPriceX96(1, 1).sub(1),
          },
          {
            withdrawTokens: true,
            settleUsingTransfer: true,
          }
        )

        const tickLower = -key.tickSpacing
        await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity)).to.be.revertedWith('InRange()')
      })
    })

    it('works with different LPs', async () => {
      const tickLower = key.tickSpacing
      const zeroForOne = true
      const liquidity = 1000000
      await limitOrderHook.place(key, tickLower, zeroForOne, liquidity)
      await limitOrderHook.connect(other).place(key, tickLower, zeroForOne, liquidity)
      expect(await limitOrderHook.getEpoch(key, tickLower, zeroForOne)).to.eq(1)

      expect(
        await manager['getLiquidity(bytes32,address,int24,int24)'](
          getPoolId(key),
          limitOrderHook.address,
          tickLower,
          tickLower + key.tickSpacing
        )
      ).to.eq(liquidity * 2)

      const epochInfo = await limitOrderHook.epochInfos(1)
      expect(epochInfo.filled).to.be.false
      expect(epochInfo.currency0).to.eq(key.currency0)
      expect(epochInfo.currency1).to.eq(key.currency1)
      expect(epochInfo.token0Total).to.eq(0)
      expect(epochInfo.token1Total).to.eq(0)
      expect(epochInfo.liquidityTotal).to.eq(liquidity * 2)

      expect(await limitOrderHook.getEpochLiquidity(1, wallet.address)).to.eq(liquidity)
      expect(await limitOrderHook.getEpochLiquidity(1, other.address)).to.eq(liquidity)
    })
  })

  describe('#kill', async () => {
    const tickLower = 0
    const zeroForOne = true
    const liquidity = 1000000

    beforeEach('create limit order', async () => {
      await limitOrderHook.place(key, tickLower, zeroForOne, liquidity)
    })

    it('works', async () => {
      await expect(limitOrderHook.kill(key, tickLower, zeroForOne, wallet.address))
        .to.emit(tokens.token0, 'Transfer')
        .withArgs(manager.address, wallet.address, 2995)

      expect(await limitOrderHook.getEpochLiquidity(1, wallet.address)).to.eq(0)
    })

    it('gas cost', async () => {
      await snapshotGasCost(limitOrderHook.kill(key, tickLower, zeroForOne, wallet.address))
    })
  })

  describe('swap across the range', async () => {
    const tickLower = 0
    const zeroForOne = true
    const liquidity = 1000000
    const expectedToken0Amount = 2996

    beforeEach('create limit order', async () => {
      await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity))
        .to.emit(tokens.token0, 'Transfer')
        .withArgs(wallet.address, manager.address, expectedToken0Amount)
    })

    beforeEach('swap', async () => {
      await expect(
        swapTest.swap(
          key,
          {
            zeroForOne: false,
            amountSpecified: expandTo18Decimals(1),
            sqrtPriceLimitX96: await tickMath.getSqrtRatioAtTick(key.tickSpacing),
          },
          {
            withdrawTokens: true,
            settleUsingTransfer: true,
          }
        )
      )
        .to.emit(tokens.token1, 'Transfer')
        .withArgs(wallet.address, manager.address, expectedToken0Amount + 19) // 3015, includes 19 wei of fees + price impact
        .to.emit(tokens.token0, 'Transfer')
        .withArgs(manager.address, wallet.address, expectedToken0Amount - 1) // 1 wei of dust

      expect(await limitOrderHook.getTickLowerLast(getPoolId(key))).to.be.eq(key.tickSpacing)

      expect((await manager.getSlot0(getPoolId(key))).tick).to.eq(key.tickSpacing)
    })

    it('#fill', async () => {
      const epochInfo = await limitOrderHook.epochInfos(1)

      expect(epochInfo.filled).to.be.true
      expect(epochInfo.token0Total).to.eq(0)
      expect(epochInfo.token1Total).to.eq(expectedToken0Amount + 17) // 3013, 2 wei of dust

      expect(
        await manager['getLiquidity(bytes32,address,int24,int24)'](
          getPoolId(key),
          limitOrderHook.address,
          tickLower,
          tickLower + key.tickSpacing
        )
      ).to.eq(0)
    })

    it('#withdraw', async () => {
      await expect(limitOrderHook.withdraw(1, wallet.address))
        .to.emit(tokens.token1, 'Transfer')
        .withArgs(manager.address, wallet.address, expectedToken0Amount + 17)

      const epochInfo = await limitOrderHook.epochInfos(1)

      expect(epochInfo.token0Total).to.eq(0)
      expect(epochInfo.token1Total).to.eq(0)
    })
  })

  describe('#afterSwap', async () => {
    const tickLower = 0
    const zeroForOne = true
    const liquidity = 1000000
    const expectedToken0Amount = 2996

    beforeEach('create limit order', async () => {
      await expect(limitOrderHook.place(key, tickLower, zeroForOne, liquidity))
        .to.emit(tokens.token0, 'Transfer')
        .withArgs(wallet.address, manager.address, expectedToken0Amount)
    })

    it('gas cost', async () => {
      await snapshotGasCost(
        swapTest.swap(
          key,
          {
            zeroForOne: false,
            amountSpecified: expandTo18Decimals(1),
            sqrtPriceLimitX96: await tickMath.getSqrtRatioAtTick(key.tickSpacing),
          },
          {
            withdrawTokens: true,
            settleUsingTransfer: true,
          }
        )
      )
    })
  })
})
