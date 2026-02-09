import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

class KycCompletedPage extends StatelessWidget {
  const KycCompletedPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Get user details from AppStore
    final store = context.watch<AppStore>();
    final userDetails = store.userDetails;
    
    // Extract user details from API response
    final data = userDetails is Map ? userDetails as Map<String, dynamic>? : null;
    final name = data?['name']?.toString() ?? data?['full_name']?.toString() ?? 'N/A';
    final pan = data?['pan']?.toString() ?? 'N/A';
    final phone = data?['phone']?.toString() ?? data?['mobile']?.toString() ?? 'N/A';
    final aadhaar = data?['aadhaar']?.toString() ?? data?['aadhar']?.toString() ?? '';
    final maskedAadhaar = aadhaar.isNotEmpty && aadhaar.length >= 4
        ? 'XXXX-XXXX-${aadhaar.substring(aadhaar.length - 4)}'
        : 'N/A';

    // Extract completed steps (assuming API returns steps array or we can infer from data)
    final completedSteps = _getCompletedSteps(data);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 40),
              // Success indicator with rings
              Stack(
                alignment: Alignment.center,
                children: [
                  // Outer ring
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green.withOpacity(0.1),
                    ),
                  ),
                  // Middle ring
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green.withOpacity(0.15),
                    ),
                  ),
                  // Inner circle with checkmark
                  Container(
                    width: 80,
                    height: 80,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.green,
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.white,
                      size: 50,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              // KYC Completed heading
              const Text(
                'KYC Completed',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 12),
              // Verification message
              Text(
                'Your account will be verified in 48 hr',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 40),
              // Customer Details card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Customer Details',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDetailRow('Name', name),
                              const SizedBox(height: 12),
                              _buildDetailRow('Pan', pan),
                            ],
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildDetailRow('Phone', phone),
                              const SizedBox(height: 12),
                              _buildDetailRow('Aadhaar', maskedAadhaar),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              // Completed Steps section
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Completed Steps',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Steps list
              ...completedSteps.map((step) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.green,
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            step,
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey[600],
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  List<String> _getCompletedSteps(Map<String, dynamic>? data) {
    // Default steps - can be customized based on API response
    final steps = <String>[
      'Mobile and Email Verification',
      'Brokerage Plan Selected',
      'Pan Verified',
      'Aadhaar Verification',
      'Photo Verification',
      'Other Details Filled',
      'Bank Details Submitted',
      'E-Sign Done',
    ];

    // If API provides steps list, use that instead
    if (data != null && data['completed_steps'] is List) {
      return (data['completed_steps'] as List)
          .map((e) => e.toString())
          .toList();
    }

    return steps;
  }
}
