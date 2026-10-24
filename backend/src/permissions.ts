export const PERMISSIONS: Record<string, string> = {
  'customer.read': 'View customers, profiles and photos',
  'customer.create': 'Register customers and capture photos',
  'customer.update': 'Edit customer details',
  'customer.delete': 'Erase customer personal data (privacy request)',
  'waiver.manage': 'Publish new waiver versions',
  'visit.read': 'View visits and daily history',
  'session.read': 'View sessions and live dashboard',
  'session.create': 'Create and start sessions',
  'session.pause': 'Pause and resume sessions',
  'session.extend': 'Extend sessions',
  'session.end': 'End sessions',
  'session.cancel': 'Cancel sessions before they start',
  'session.correct': 'Correct session mistakes (audited)',
  'session.override_capacity': 'Start a session when the venue is full',
  'payment.create': 'Record payments',
  'payment.read': 'View payments',
  'payment.discount': 'Apply discounts / complimentary sessions',
  'payment.refund': 'Issue refunds',
  'equipment.read': 'View equipment',
  'equipment.assign': 'Issue equipment',
  'equipment.return': 'Receive returned equipment',
  'equipment.maintenance': 'Report damage and manage maintenance',
  'equipment.manage': 'Add and retire equipment units',
  'equipment.cleaning': 'Clean rental skates and manage the cleaning queue',
  'shoeclaim.manage': "Store, search and return customers' personal shoes",
  'incident.create': 'Report incidents',
  'incident.read': 'View incident details',
  'incident.manage': 'Progress and close incidents',
  'reports.read': 'View reports',
  'staff.manage': 'Manage staff accounts and roles',
  'settings.manage': 'Change venue settings',
  'pricing.manage': 'Change pricing',
  'capacity.manage': 'Change venue capacity',
  'audit.read': 'View the audit log',
  'device.manage': 'Register and manage devices',
  'dayclose.manage': 'Close the day',
  'loyalty.read': 'View customer loyalty cards, rewards and history',
  'loyalty.stamp': 'Award loyalty stamps for verified paid skating sessions',
  'loyalty.redeem': 'Validate and redeem loyalty rewards',
  'loyalty.correct': 'Void loyalty stamps/rewards (audited corrections)',
  'playstation.operate': 'Run PlayStation gaming sessions and record their payments',
  'playstation.manage': 'Manage PlayStation consoles, packages, prices and settings',
  'playstation.reports': 'View PlayStation reports, revenue and employee activity',
  'playstation.refund': 'Refund PlayStation payments',
};

const ALL = Object.keys(PERMISSIONS);
const not = (...x: string[]) => ALL.filter((p) => !x.includes(p));
// The PlayStation business is its own module: only Owner/Admin and the dedicated PlayStation Manager role get it.
const PLAYSTATION = ALL.filter((p) => p.startsWith('playstation.'));
const LOYALTY_DESK = ['loyalty.read', 'loyalty.stamp', 'loyalty.redeem'];

export const DEFAULT_ROLES: { code: string; name: string; permissions: string[] }[] = [
  { code: 'OWNER', name: 'Owner', permissions: ALL },
  { code: 'ADMIN', name: 'Admin', permissions: ALL },
  {
    code: 'MANAGER',
    name: 'Manager',
    permissions: not('staff.manage', 'settings.manage', 'customer.delete', 'pricing.manage', ...PLAYSTATION),
  },
  {
    code: 'SUPERVISOR',
    name: 'Supervisor',
    permissions: [
      'customer.read', 'customer.create', 'customer.update', 'visit.read',
      'session.read', 'session.create', 'session.pause', 'session.extend', 'session.end', 'session.cancel',
      'session.correct', 'payment.create', 'payment.read', 'payment.discount', 'payment.refund',
      'equipment.read', 'equipment.assign', 'equipment.return', 'equipment.maintenance', 'equipment.cleaning',
      'incident.create', 'incident.read', 'incident.manage', 'shoeclaim.manage', ...LOYALTY_DESK,
    ],
  },
  {
    code: 'FRONT_DESK',
    name: 'Front Desk',
    permissions: [
      'customer.read', 'customer.create', 'customer.update', 'visit.read',
      'session.read', 'session.create', 'session.pause', 'session.extend', 'session.end', 'session.cancel',
      'payment.create', 'payment.read',
      'equipment.read', 'equipment.assign', 'equipment.return',
      'incident.create', 'shoeclaim.manage', ...LOYALTY_DESK,
    ],
  },
  {
    code: 'RENTAL_STAFF',
    name: 'Rental Staff',
    permissions: [
      'customer.read', 'visit.read', 'session.read',
      'equipment.read', 'equipment.assign', 'equipment.return', 'equipment.maintenance', 'equipment.cleaning',
      'incident.create', 'shoeclaim.manage',
    ],
  },
  {
    code: 'PLAYSTATION_MANAGER',
    name: 'PlayStation Manager',
    permissions: ['playstation.operate'],
  },
];
