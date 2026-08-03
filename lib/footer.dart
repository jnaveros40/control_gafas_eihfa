import 'package:flutter/material.dart';

class Footer extends StatelessWidget {
  const Footer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      // Fondo azul oscuro para todo el footer
      color: const Color(0xFF0A1628), 
      padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 20.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Sección Izquierda: Logo Fuerza Aeroespacial
          _buildLeftLogo(),

          // 2. Sección Central: Tarjeta de Desarrollador
          _buildDeveloperCard(),

          // 3. Sección Derecha: Escudo EIHFA
          _buildRightLogo(),
        ],
      ),
    );
  }

  Widget _buildLeftLogo() {
    return SizedBox(
      width: 100, // Ajusta el tamaño según necesites
      height: 50,
      child: Image.asset(
        'lib/public/LogosFAC/Marca Fuerza Aeroespacial Colombiana-Blanco.png',
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.flight_takeoff, color: Colors.white54, size: 24),
            SizedBox(height: 4),
            Text(
              'LOGO FAC',
              style: TextStyle(color: Colors.white54, fontSize: 8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeveloperCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF050B14), // Un azul aún más oscuro para que la caja resalte ligeramente
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo IngNavs (Circular)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.orangeAccent.withOpacity(0.5)),
            ),
            child: ClipOval(
              child: Image.asset(
                'lib/public/LogosFAC/IngNavs.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Text(
                    'NG',
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Textos del desarrollador
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Desarrollado por: Ing Navs',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white, 
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _PulsingDot(),
                  const SizedBox(width: 6),
                  const Text(
                    'Versión 1.0.0',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRightLogo() {
    return SizedBox(
      width: 50, // Ajusta el tamaño según necesites
      height: 60,
      child: Image.asset(
        'lib/public/LogosFAC/ESCUDO EIHFA.png',
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.shield, color: Colors.white54, size: 24),
            SizedBox(height: 4),
            Text(
              'EIHFA',
              style: TextStyle(color: Colors.white54, fontSize: 8),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Opacity(
          opacity: _animation.value,
          child: Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: Color(0xFF00FF66),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}