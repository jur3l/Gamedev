extends Node2D
## Purely cosmetic effects via GPUParticles2D. Completely decoupled from the
## Cellular Automata simulation - no physics bodies, no per-cell particles,
## just short-lived one-shot bursts spawned on mining/building events.

func spawn_burst(world_pos: Vector2, color: Color, amount: int = 12) -> void:
	var particles := GPUParticles2D.new()
	add_child(particles)
	particles.global_position = world_pos
	particles.amount = amount
	particles.lifetime = 0.5
	particles.one_shot = true
	particles.explosiveness = 0.9
	particles.emitting = false

	var mat := ParticleProcessMaterial.new()
	mat.direction = Vector3(0, -1, 0)
	mat.spread = 180.0
	mat.gravity = Vector3(0, 260, 0)
	mat.initial_velocity_min = 20.0
	mat.initial_velocity_max = 70.0
	mat.scale_min = 1.0
	mat.scale_max = 2.5
	mat.color = color
	particles.process_material = mat

	var tex := GradientTexture2D.new()
	tex.width = 2
	tex.height = 2
	particles.texture = tex

	particles.emitting = true
	get_tree().create_timer(particles.lifetime + 0.2).timeout.connect(particles.queue_free)

func spawn_dust(world_pos: Vector2) -> void:
	spawn_burst(world_pos, Color(0.75, 0.68, 0.55, 0.9), 14)

func spawn_build_puff(world_pos: Vector2) -> void:
	spawn_burst(world_pos, Color(0.6, 0.6, 0.65, 0.9), 8)
