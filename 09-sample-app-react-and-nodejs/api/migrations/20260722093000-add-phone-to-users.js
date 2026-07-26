'use strict';

module.exports = {
  async up(queryInterface, Sequelize) {
    await queryInterface.addColumn('users', 'phone_number', {
      type: Sequelize.STRING(20),
      allowNull: true,
      defaultValue: null,
      after: 'email'
    });
  },

  async down(queryInterface) {
    await queryInterface.removeColumn('users', 'phone_number');
  }
};
