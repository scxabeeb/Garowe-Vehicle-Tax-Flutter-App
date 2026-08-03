import 'package:flutter/material.dart';

class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      currentIndex: currentIndex,
      backgroundColor: Colors.white,
      selectedItemColor: const Color(0xFF0B57D0),
      unselectedItemColor: Colors.blueGrey.shade500,
      selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12),
      elevation: 4,
      onTap: onTap,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'Payments'),
        BottomNavigationBarItem(icon: Icon(Icons.payments), label: 'New Payment'),
        BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        BottomNavigationBarItem(icon: Icon(Icons.print), label: 'Printer'),
      ],
    );
  }
}
