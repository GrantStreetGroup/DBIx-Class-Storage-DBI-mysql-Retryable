# Add your requirements here
requires 'perl', 'v5.10.0'; # for kwalitee

# Direct requirements
requires 'Context::Preserve';
requires 'namespace::clean';

# Indirect (or bundled) requirements
requires 'DBI';
requires 'DBD::mysql';
requires 'DBIx::Class';

# Test requirements
on test => sub {
    requires 'Class::Load';
    requires 'Path::Class';
    requires 'Test2::Suite';
};

on develop => sub {
    requires 'Dist::Zilla::PluginBundle::Author::GSG';
};
