require "/scripts/util.lua"
require "/scripts/interp.lua"

-- Base gun fire ability
StarforgeGunFire = WeaponAbility:new()

function StarforgeGunFire:init()
  self.weapon:setStance(self.stances.idle)

  self.cooldownTimer = self.fireTime

  self.weapon.onLeaveAbility = function()
    self.weapon:setStance(self.stances.idle)
  end
end

function StarforgeGunFire:update(dt, fireMode, shiftHeld)
  WeaponAbility.update(self, dt, fireMode, shiftHeld)

  self.cooldownTimer = math.max(0, self.cooldownTimer - self.dt)

  if animator.animationState("firing") ~= "fire" then
    animator.setLightActive("muzzleFlash", false)
  end

  if self.fireMode == (self.activatingFireMode or self.abilitySlot)
    and not self.weapon.currentAbility
    and self.cooldownTimer == 0
    and not status.resourceLocked("energy")
    and not world.lineTileCollision(mcontroller.position(), self:firePosition()) then

    if self.fireType == "auto" and status.overConsumeResource("energy", self:energyPerShot()) then
      self:setState(self.auto)
    elseif self.fireType == "burst" then
      self:setState(self.burst)
    elseif self.fireType == "charge" and status.overConsumeResource("energy", self:energyPerShot()) then
      self:setState(self.charge)
    end
  end
  
  if self.remoteDetonateProjectile then
    if self.fireMode == "alt" and self.projectileId then
	  world.callScriptedEntity(self.projectileId, "detonate")
	  self.projectileId = nil
	end
  end
end

function StarforgeGunFire:auto()
  self.weapon:setStance(self.stances.fire)

  self.projectileId = self:fireProjectile()
  self:muzzleFlash()

  if self.stances.fire.duration then
    util.wait(self.stances.fire.duration)
  end

  self.cooldownTimer = self.fireTime
  self:setState(self.cooldown)
end

function StarforgeGunFire:charge()
  if animator.hasSound("chargeLoop") then
    animator.playSound("chargeLoop", -1)
  end
  --Timer used for optional shaking
  local timer = 0
  util.wait(self.chargeTime, function()
	--Optional particle emitter
	if self.chargeParticleEmitter then
	  animator.setParticleEmitterActive(self.stances.fire.particleEmitter, true)
	  self.currentParticleEmitter = self.stances.fire.particleEmitter
	end
    if self.chargeShake then
	  local wavePeriod = (self.chargeShakeWavePeriod or 0.125) / (2 * math.pi) / (1 + (timer * (self.chargeShakeFactor or 1)))
	  local waveAmplitude = (self.chargeShakeWaveAmplitude or 0.075) * (1 + (timer * (self.chargeShakeFactor or 1)))
	
	  timer = timer + self.dt
	  local rotation = waveAmplitude * math.sin(timer / wavePeriod)
	
	  self.weapon.relativeArmRotation = rotation + util.toRadians(self.stances.idle.armRotation) --Add weaponRotation again, as relativeWeaponRotation overwrites it
    end
  end)
  animator.stopAllSounds("chargeLoop")
  
  if self.windDownAnimation then
    
  end
  
  self.weapon:setStance(self.stances.fire)

  self.projectileId = self:fireProjectile()
  self:muzzleFlash()

  self.cooldownTimer = self.fireTime
  self:setState(self.cooldown)
end

function StarforgeGunFire:burst()
  self.weapon:setStance(self.stances.fire)

  local shots = self.burstCount
  while shots > 0 and status.overConsumeResource("energy", self:energyPerShot()) do
    self.projectileId = self:fireProjectile()
    self:muzzleFlash()
    shots = shots - 1

    self.weapon.relativeWeaponRotation = util.toRadians(interp.linear(1 - shots / self.burstCount, 0, self.stances.fire.weaponRotation))
    self.weapon.relativeArmRotation = util.toRadians(interp.linear(1 - shots / self.burstCount, 0, self.stances.fire.armRotation))

    util.wait(self.burstTime)
  end

  self.cooldownTimer = (self.fireTime - self.burstTime) * self.burstCount
  self:setState(self.cooldown)
end

function StarforgeGunFire:cooldown()
  self.weapon:setStance(self.stances.cooldown)
  self.weapon:updateAim()

  local progress = 0
  util.wait(self.stances.cooldown.duration, function()
    local from = self.stances.cooldown.weaponOffset or {0,0}
    local to = self.stances.idle.weaponOffset or {0,0}
    self.weapon.weaponOffset = {util.interpolateHalfSigmoid(progress, from[1], to[1]), util.interpolateHalfSigmoid(progress, from[2], to[2])}

    self.weapon.relativeWeaponRotation = util.toRadians(util.interpolateHalfSigmoid(progress, self.stances.cooldown.weaponRotation, self.stances.idle.weaponRotation))
    self.weapon.relativeArmRotation = util.toRadians(util.interpolateHalfSigmoid(progress, self.stances.cooldown.armRotation, self.stances.idle.armRotation))

    progress = math.min(1.0, progress + (self.dt / self.stances.cooldown.duration))
  end)
end

function StarforgeGunFire:muzzleFlash()
  animator.setPartTag("muzzleFlash", "variant", math.random(1, self.muzzleFlashVariants or 3))
  animator.setAnimationState("firing", "fire")
  
  animator.burstParticleEmitter("muzzleFlash")
  
  --Add normal pitch variance to shots
  local pitchVariance = (1 + (self.pitchVariance or 0.15)) - (math.random() * ((self.pitchVariance or 0.15) * 2))
  animator.setSoundPitch("fire", pitchVariance)
  animator.playSound("fire")

  animator.setLightActive("muzzleFlash", true)
end

function StarforgeGunFire:fireProjectile(projectileType, projectileParams, inaccuracy, firePosition, projectileCount)
  local params = sb.jsonMerge(self.projectileParameters, projectileParams or {})
  params.power = self:damagePerShot()
  params.powerMultiplier = activeItem.ownerPowerMultiplier()

  if not projectileType then
    projectileType = self.projectileType
  end
  if type(projectileType) == "table" then
    projectileType = projectileType[math.random(#projectileType)]
  end

  local projectileId = 0
  for i = 1, (projectileCount or self.projectileCount) do
    if params.timeToLive then
      params.timeToLive = util.randomInRange(params.timeToLive)
    end

    projectileId = world.spawnProjectile(
        projectileType,
        firePosition or self:firePosition(),
        activeItem.ownerEntityId(),
        self:aimVector(inaccuracy or self.inaccuracy),
        false,
        params
      )
  end
  return projectileId
end

function StarforgeGunFire:firePosition()
  return vec2.add(mcontroller.position(), activeItem.handPosition(self.weapon.muzzleOffset))
end

function StarforgeGunFire:aimVector(inaccuracy)
  local aimVector = vec2.rotate({1, 0}, self.weapon.aimAngle + sb.nrand(inaccuracy, 0))
  aimVector[1] = aimVector[1] * mcontroller.facingDirection()
  return aimVector
end

function StarforgeGunFire:energyPerShot()
  return self.energyUsage * self.fireTime * (self.energyUsageMultiplier or 1.0)
end

function StarforgeGunFire:damagePerShot()
  return (self.baseDamage or (self.baseDps * self.fireTime)) * (self.baseDamageMultiplier or 1.0) * config.getParameter("damageLevelMultiplier") / self.projectileCount
end

function StarforgeGunFire:uninit()
end
