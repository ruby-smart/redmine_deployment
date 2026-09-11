/* Deployment pipeline table (plugin settings and project settings, tab "Deployment"): the static step "Code" (first
 * row, only label and color), then the environments (sortable).
 * The table is saved as text: one line per row in the order of the table (hidden field) - "code | | <label> | <color>"
 * and "<type> | <value> | <label> | <color>", every line is checked with the pattern of the parser
 * (RedmineDeployment::Environments::PATTERN).
 * Project settings: without own environments (checkbox .deployment-environments-custom) the table shows the central
 * environments read-only and is not submitted. */
(function ($) {
  'use strict';

  var CONTAINER = '.deployment-environments';

  function EnvironmentsTable(container) {
    this.$container = $(container);
    this.$field = this.$container.find('input.deployment-environments-field');
    this.$body = this.$container.find('.deployment-environments-table tbody');
    this.pattern = new RegExp(this.$field.attr('data-pattern'));
    this.colors = this.$field.data('colors') || [];

    this.initSortable();
    this.initButtons();
    this.initCustom();
    this.sync();
  }

  EnvironmentsTable.prototype.rows = function () {
    return this.$body.children('tr.deployment-environment');
  };

  EnvironmentsTable.prototype.disabled = function () {
    return this.$container.hasClass('deployment-environments-disabled');
  };

  EnvironmentsTable.prototype.initSortable = function () {
    var self = this;

    this.$body.sortable({
      items: '> tr.deployment-environment',
      handle: '.sort-handle',
      axis: 'y',
      // keeps the widths of the cells while dragging
      helper: function (event, $row) {
        var $helper = $row.clone();
        $helper.children().each(function (index) { $(this).width($row.children().eq(index).width()); });
        return $helper;
      },
      update: function () { self.sync(); }
    });
  };

  EnvironmentsTable.prototype.initButtons = function () {
    var self = this;

    this.$container.on('click', '.deployment-environment-add', function (event) {
      event.preventDefault();
      if (!self.disabled()) { self.add(); }
    });
    this.$container.on('click', '.deploy-env-delete', function (event) {
      event.preventDefault();
      if (self.disabled()) { return; }
      $(this).closest('tr').remove();
      self.sync();
    });
    this.$container.on('input change', '.deployment-environment :input, .deployment-code :input', function () { self.sync(); });
  };

  // project settings: own environments or the central ones (read-only, not submitted)
  EnvironmentsTable.prototype.initCustom = function () {
    var self = this;
    var $custom = this.$container.closest('form').find('input.deployment-environments-custom');
    if (!$custom.length) { return; }

    $custom.on('change', function () { self.setDisabled(!this.checked); });
    this.setDisabled(!$custom.prop('checked'));
  };

  EnvironmentsTable.prototype.setDisabled = function (disabled) {
    this.$container.toggleClass('deployment-environments-disabled', disabled);
    this.$body.find(':input').prop('disabled', disabled);
    this.$field.prop('disabled', disabled);
    this.$body.sortable(disabled ? 'disable' : 'enable');
    this.sync();
  };

  // a new row - its color is the next default color (by position)
  EnvironmentsTable.prototype.add = function () {
    var $row = $($.trim(this.$container.find('template.deployment-environment-template').html()));
    var color = this.colors[this.rows().length % Math.max(this.colors.length, 1)];

    if (color) { $row.find('.deploy-env-color').val(color); }
    this.$body.append($row);
    this.sync();
    $row.find('.deploy-env-value').trigger('focus');
  };

  // writes the rows into the hidden field and marks the invalid rows - returns true, if all rows are valid
  EnvironmentsTable.prototype.sync = function () {
    var self = this;
    var lines = [];
    var invalid = [];
    var $code = this.$body.children('tr.deployment-code');

    // the step "Code" (row 1), then the environments
    $code.add(this.rows()).each(function (index) {
      var $row = $(this);
      var code = $row.hasClass('deployment-code');
      var line = [
        code ? 'code' : $row.find('.deploy-env-type').val(),
        code ? '' : $.trim($row.find('.deploy-env-value').val()),
        $.trim($row.find('.deploy-env-label').val()),
        $row.find('.deploy-env-color').val()
      ].join(' | ');
      var valid = self.pattern.test(line);

      $row.toggleClass('deploy-env-invalid', !valid);
      if (!valid) { invalid.push(index + 1); }
      lines.push(line);
    });

    this.$field.val(lines.join('\n'));
    this.$container.find('.deployment-environments-empty').toggle(this.rows().length === 0);
    // read-only: the central environments are not checked
    if (this.disabled()) { invalid = []; }

    var $error = this.$container.find('.deployment-environments-error');
    $error.text(invalid.length ? this.$field.attr('data-message').replace('%{lines}', invalid.join(', ')) : '');
    $error.toggle(invalid.length > 0);
    return invalid.length === 0;
  };

  $(function () {
    $(CONTAINER).each(function () { $(this).data('deployment-environments', new EnvironmentsTable(this)); });

    // don't save invalid rows (the parser would ignore them) - show the tab of the table instead. Captured before
    // rails-ujs sees the submit, which would disable the submit button.
    document.addEventListener('submit', function (event) {
      var $invalid = $(event.target).find(CONTAINER).filter(function () {
        return !$(this).data('deployment-environments').sync();
      }).first();
      if (!$invalid.length) { return; }

      event.preventDefault();
      event.stopPropagation();
      var $row = $invalid.find('tr.deploy-env-invalid').first();
      var $input = $row.find('.deploy-env-value').add($row.find('.deploy-env-label')).first();
      var tab = ($invalid.closest('.tab-content').attr('id') || '').replace(/^tab-content-/, '');
      if (tab && !$row.is(':visible')) { $('#tab-' + tab).trigger('click'); }
      $input.trigger('focus');
    }, true);
  });
})(jQuery);
