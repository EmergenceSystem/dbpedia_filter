use actix_web::{post, App, HttpServer, HttpResponse, Responder};
use std::string::String;
use reqwest::Client;
use embryo::{Embryo, EmbryoList};
use serde_json::{Value, from_str};
use std::collections::HashMap;
use std::time::{Instant, Duration};

const DBPEDIA_ENDPOINT: &str = "https://dbpedia.org/sparql";

#[post("/query")]
async fn query_handler(body: String) -> impl Responder {
    let embryo_list = generate_embryo_list(body).await;
    let response = EmbryoList { embryo_list };
    HttpResponse::Ok().json(response)
}

async fn generate_embryo_list(json_string: String) -> Vec<Embryo> {
    let mut embryo_list = Vec::new();
    let search: HashMap<String,String> = from_str(&json_string).expect("Can't parse JSON");
    let value = match search.get("value") {
        Some(v) => v,
        None => "",
    };
    let timeout_secs : u64 = match search.get("timeout") {
        Some(t) => t.parse().expect("Can't parse as u64"),
        None => 10,
    };
    let dbo = match search.get("dbo") {
        Some(v) => v,
        None => "Company", // Default is Company
    };

    let query = format!(r#"
        PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
        SELECT DISTINCT ?url ?abstract
        WHERE {{
            {{
            ?s a ?type ;
                rdfs:label ?label ;
                <http://dbpedia.org/ontology/abstract> ?abstract ;
                foaf:isPrimaryTopicOf ?url .
                FILTER (langMatches(lang(?abstract), "en"))
                FILTER (contains(?label, "{}"))
                FILTER (?type IN (<http://dbpedia.org/ontology/{}>))
            }}
        }}
    "#, value, dbo);

    let start_time = Instant::now();
    let timeout = Duration::from_secs(timeout_secs);

    let client = Client::new();
    let response = client.post(DBPEDIA_ENDPOINT)
        .header("Accept", "application/sparql-results+json")
        .form(&[("query", query)])
        .send()
        .await;

    match response {
        Ok(response) => {
            if response.status().is_success() {
                if let Ok(body) = response.text().await {
                    if let Ok(json) = serde_json::from_str::<Value>(&body) {
                        let bindings = json["results"]["bindings"].as_array().unwrap();
                        for result in bindings {
                            if start_time.elapsed() >= timeout {
                                return embryo_list;
                            }

                            let url = result["url"]["value"].as_str().unwrap();
                            let resume = result["abstract"]["value"].as_str().unwrap();
                            let embryo = Embryo {
                                properties: HashMap::from([("url".to_string(), url.to_string()),("resume".to_string(),resume.to_string())])
                            };
                            embryo_list.push(embryo);
                        }
                    } else {
                        println!("Can't parse JSON");
                    }
                } else {
                    println!("Can't read response");
                }

            } else {
                println!("Response code : {}", response.status());
            }
        }
        Err(err) => {
            println!("Query error : {}", err);
        }
    } 

    embryo_list
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    match em_filter::find_port().await {
        Some(port) => {
            let filter_url = format!("http://localhost:{}/query", port);
            println!("Filter registrer: {}", filter_url);
            em_filter::register_filter(&filter_url).await;
            HttpServer::new(|| App::new().service(query_handler))
                .bind(format!("127.0.0.1:{}", port))?.run().await?;
        },
        None => {
            println!("Can't start");
        },
    }
    Ok(())
}

