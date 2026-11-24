/**
 * cbLocalDB: qb accessors for the database running inside this container.
 * In:  moduleSettings[ "cb-localdb" ] = { datasource, grammar, defaultSchema }
 * Out: WireBox ids LocalQB@cb-localdb ( QueryBuilder ) and LocalSB@cb-localdb ( SchemaBuilder )
 *      property name="qb2" inject="provider:LocalQB@cb-localdb";
 */
component {

	this.name         = "cb-localdb";
	this.author       = "John Wilson";
	this.webUrl       = "https://github.com/Daemach/cb-localdb";
	this.cfmapping    = "cb-localdb";
	this.dependencies = [ "qb" ];

	function configure() {
		settings = {
			// Name of the CFML datasource that points at the local database
			"datasource"    : "localdb",
			// WireBox id of the qb grammar ( PostgresGrammar@qb for the postgres engine )
			"grammar"       : "SqlServerGrammar@qb",
			"defaultSchema" : "dbo"
		};
	}

	function onLoad() {
		binder
			.map( "LocalQB@cb-localdb" )
			.to( "qb.models.Query.QueryBuilder" )
			.initArg( name = "grammar", ref = settings.grammar )
			.initArg( name = "defaultOptions", value = { "datasource" : settings.datasource } );

		binder
			.map( "LocalSB@cb-localdb" )
			.to( "qb.models.Schema.SchemaBuilder" )
			.initArg( name = "grammar", ref = settings.grammar )
			.initArg( name = "defaultOptions", value = { "datasource" : settings.datasource } )
			.initArg( name = "defaultSchema", value = settings.defaultSchema );
	}

}
